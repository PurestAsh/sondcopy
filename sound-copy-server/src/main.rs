use std::net::UdpSocket;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use flexaudio::{SourceKind, StreamConfig, open};
use gpui_kit::{
    AppContext, Context, Entity, ParentElement, Render, Task, WindowBounds, WindowOptions,
    application,
    assets::Assets,
    base::{StyledExt, input::InputState},
    component::{
        button::Button,
        input::Input,
        theme::{Theme, ThemeMode},
    },
    div, init, open_window, px, size,
};

struct State {
    caputure: bool,
    target_host: String,
    task: Option<Task<()>>,
    /// 通知后台采集线程停止（Task 的 drop 无法打断阻塞循环）。
    stop_flag: Arc<AtomicBool>,
    input_state: Entity<InputState>,
}

impl State {
    fn new(window: &mut gpui_kit::Window, cx: &mut Context<Self>) -> Self {
        let input_state = cx.new(|cx| {
            InputState::new(window, cx).default_value("192.168.31.103:9000")
        });
        Self {
            caputure: false,
            target_host: String::from("192.168.31.103:9000"),
            task: None,
            stop_flag: Arc::new(AtomicBool::new(false)),
            input_state,
        }
    }
}

impl Render for State {
    fn render(
        &mut self,
        _window: &mut gpui_kit::Window,
        cx: &mut gpui_kit::prelude::Context<Self>,
    ) -> impl gpui_kit::prelude::IntoElement {
        div()
            .v_flex()
            .child(Input::new(&self.input_state))
            .child(
                Button::new("caputure")
                    .label(if self.caputure {
                        "结束采集"
                    } else {
                        "开始采集"
                    })
                    .on_click(cx.listener(|state, _, _, cx| {
                        //MARK: 开始采集
                        if !state.caputure {
                            let addr =
                                state.input_state.read(cx).content().text().to_string();
                            state.target_host = addr;
                            caputure(cx, state)
                        } else {
                            // 先通知后台循环退出，再释放 Task 句柄。
                            state.stop_flag.store(true, Ordering::Relaxed);
                            state.task = None;
                        }

                        state.caputure = !state.caputure;
                        cx.notify();
                    })),
            )
    }
}

fn main() {
    application().with_assets(Assets).run(|cx| {
        init(cx);
        Theme::change(ThemeMode::Dark, None, cx);

        open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::centered(size(px(400.), px(400.)), cx)),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| State::new(window, cx)),
        )
        .expect("build failed");
    });
}

fn caputure(cx: &mut Context<State>, state: &mut State) {
    let target_host = state.target_host.clone();
    let stop = Arc::new(AtomicBool::new(false));
    state.stop_flag = stop.clone();

    // 放到后台执行，避免采集/发送循环卡住 UI 线程。
    state.task = Some(cx.background_spawn(async move {
        // 只创建一次 socket。
        // 必须绑定 0.0.0.0（或本机局域网网卡地址），不能绑 127.0.0.1：
        // 绑定回环地址后向局域网地址 send_to 会返回 EINVAL。
        // 端口用 0 让系统随机分配即可（接收端已不再用 connect 过滤源端口）。
        let socket = match UdpSocket::bind("0.0.0.0:0") {
            Ok(socket) => socket,
            Err(err) => {
                eprintln!("绑定本地 UDP 端口失败: {err}");
                return;
            }
        };

        let mut stream = match open(StreamConfig {
            kind: SourceKind::SystemLoopback,
            ..Default::default()
        }) {
            Ok(stream) => stream,
            Err(err) => {
                eprintln!("打开系统回环音频失败: {err}");
                return;
            }
        };
        if let Err(err) = stream.start() {
            eprintln!("启动音频采集失败: {err}");
            return;
        }

        let mut last_report = std::time::Instant::now();
        let mut sent_packets: u64 = 0;
        let mut pending_error: Option<String>;

        // 关键：poll_chunk() 是「非阻塞」的，没有新数据时会返回 None。
        // 不能用 while let Some(..)，否则第一次 poll 返回 None 时循环就直接结束，
        // 一个包都不会发。这里改成持续轮询，没数据时短暂休眠再试。
        while !stop.load(Ordering::Relaxed) {
            let Some(chunk) = stream.poll_chunk() else {
                std::thread::sleep(std::time::Duration::from_millis(2));
                continue;
            };

            // interleaved f32, plus frames / peak / rms / seq
            let mut data = Vec::with_capacity(chunk.data.len() * 4);
            for sample in &chunk.data {
                data.extend_from_slice(&sample.to_le_bytes());
            }

            match socket.send_to(&data, &target_host) {
                Ok(_) => {
                    sent_packets += 1;
                    pending_error = None;
                }
                Err(err) => {
                    pending_error = Some(err.to_string());
                }
            }

            // 每秒打印一次，确认「采集到了非静音数据」且「确实发出去了」。
            if last_report.elapsed() >= std::time::Duration::from_secs(1) {
                eprintln!(
                    "已发送 {sent_packets} 包，每包 {} 字节，采集峰值 {:.4}{}",
                    data.len(),
                    chunk.peak,
                    pending_error
                        .as_ref()
                        .map(|err| format!("，发送失败: {err}"))
                        .unwrap_or_default()
                );
                last_report = std::time::Instant::now();
            }
        }

        stream.stop();
        eprintln!("采集已停止，共发送 {sent_packets} 包");
    }));
}
