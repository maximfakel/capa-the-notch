//! The system going to sleep, as logind says it: `PrepareForSleep(true)` from
//! `org.freedesktop.login1.Manager` on the system bus. The Swift app hears
//! `NSWorkspace.willSleepNotification` and lets go of the held key and the
//! session; this is the same moment on Linux.

use crate::driver::SleepWatch;
use futures_util::StreamExt;

const DESTINATION: &str = "org.freedesktop.login1";
const PATH: &str = "/org/freedesktop/login1";
const INTERFACE: &str = "org.freedesktop.login1.Manager";
const SIGNAL: &str = "PrepareForSleep";

/// logind, on the system bus. Where there is none (a container, a system
/// without systemd) nothing is heard, and nothing else changes.
pub struct Logind;

impl SleepWatch for Logind {
    fn start(self: Box<Self>, will_sleep: Box<dyn Fn() + Send + Sync>) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        runtime.spawn(async move {
            // No bus, or no logind on it: sleep goes unheard, as before.
            let _ = listen(&*will_sleep).await;
        });
    }
}

async fn listen(will_sleep: &(dyn Fn() + Send + Sync)) -> zbus::Result<()> {
    let connection = zbus::Connection::system().await?;
    let proxy = zbus::Proxy::new(&connection, DESTINATION, PATH, INTERFACE).await?;
    let mut signals = proxy.receive_signal(SIGNAL).await?;
    while let Some(message) = signals.next().await {
        if going_to_sleep(message.body().deserialize::<bool>().ok()) {
            will_sleep();
        }
    }
    Ok(())
}

/// `PrepareForSleep` is sent twice: `true` before sleeping, `false` on waking.
fn going_to_sleep(argument: Option<bool>) -> bool {
    argument == Some(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_notice_before_sleep_counts() {
        assert!(going_to_sleep(Some(true)));
        assert!(!going_to_sleep(Some(false)), "waking is not sleeping");
        assert!(!going_to_sleep(None));
    }
}
