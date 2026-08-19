//! Which network link a session is actually using (Task 10.2).
//!
//! Wi-Fi jitter is the largest remaining source of felt lag, and the fix is a
//! cable rather than a quality trade-off. But telling someone to use a cable is
//! useless if the app cannot say what they are on now — so this names the
//! adapter carrying the stream and whether it is wired.
//!
//! The classification is deliberately free of Windows types so it can be tested
//! anywhere; only the enumeration is platform-specific.

/// A link the stream can run over.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub struct LinkInfo {
    /// The adapter's friendly name, e.g. "Ethernet" or "Wi-Fi".
    pub name: String,
    /// Human-readable kind, e.g. "Ethernet", "Wi-Fi", "Thunderbolt".
    pub kind: String,
    pub wired: bool,
    pub local_ip: String,
    /// Negotiated receive speed in Mbps, 0 when unknown.
    pub speed_mbps: u64,
    /// True when the address is link-local (169.254.x.x), which is what a direct
    /// cable between two machines self-assigns with no DHCP server present.
    pub direct: bool,
}

/// IANA interface types, as reported in IP_ADAPTER_ADDRESSES_LH::IfType.
pub const IF_TYPE_ETHERNET: u32 = 6;
pub const IF_TYPE_LOOPBACK: u32 = 24;
pub const IF_TYPE_WIFI: u32 = 71;
pub const IF_TYPE_TUNNEL: u32 = 131;

/// Maps an interface type to a name and whether it is wired.
///
/// Thunderbolt and USB4 networking both present as ETHERNET, which is correct:
/// what matters to latency is that it is a cable, not which connector it uses.
pub fn classify(if_type: u32) -> (&'static str, bool) {
    match if_type {
        IF_TYPE_ETHERNET => ("Ethernet", true),
        IF_TYPE_WIFI => ("Wi-Fi", false),
        IF_TYPE_LOOPBACK => ("Loopback", true),
        IF_TYPE_TUNNEL => ("Tunnel", false),
        // Unknown types are reported as wireless on purpose: claiming a cable
        // that is not there would suppress the one suggestion worth making.
        _ => ("Other", false),
    }
}

/// True for 169.254.0.0/16, the address a machine self-assigns when nothing
/// hands out leases — the normal state of a cable run straight between two
/// computers.
pub fn is_link_local(ip: &str) -> bool {
    ip.strip_prefix("169.254.")
        .map(|rest| rest.split('.').count() == 2)
        .unwrap_or(false)
}

/// Advice worth showing, or None when the link is already good.
///
/// Only speaks up when there is something to gain: a wired link, however slow
/// the numbers look, has nothing to offer here.
pub fn suggestion(link: Option<&LinkInfo>, delay_ms: f64) -> Option<String> {
    let link = link?;
    if link.wired {
        return None;
    }
    if delay_ms < 40.0 {
        return None;
    }
    Some(format!(
        "{} is adding about {delay_ms:.0} ms of delay. A cable between the two \
         machines removes it — Ethernet, or Thunderbolt if both ends support it.",
        link.name
    ))
}

#[cfg(target_os = "windows")]
mod platform {
    use super::{classify, is_link_local, LinkInfo};
    use std::net::IpAddr;
    use windows::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER,
        GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows::Win32::Networking::WinSock::{AF_UNSPEC, SOCKADDR_IN, SOCKADDR_IN6};

    const ERROR_BUFFER_OVERFLOW: u32 = 111;

    /// Finds the adapter that owns `local_ip` — the address the connected socket
    /// is actually using, which is the only reliable way to know which link
    /// carries the stream on a machine with several.
    pub fn describe(local_ip: IpAddr) -> Option<LinkInfo> {
        let wanted = local_ip.to_string();
        let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;

        // Called twice by design: the first call reports the size needed, which
        // changes as adapters come and go.
        let mut size: u32 = 0;
        unsafe {
            if GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, None, &mut size)
                != ERROR_BUFFER_OVERFLOW
            {
                return None;
            }
        }
        let mut buffer = vec![0u8; size as usize];
        let head = buffer.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        unsafe {
            if GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, Some(head), &mut size) != 0 {
                return None;
            }
        }

        let mut adapter = head;
        while !adapter.is_null() {
            let current = unsafe { &*adapter };
            let mut unicast = current.FirstUnicastAddress;
            while !unicast.is_null() {
                let entry = unsafe { &*unicast };
                if let Some(address) = unsafe { socket_address_to_string(&entry.Address) } {
                    if address == wanted {
                        let (kind, wired) = classify(current.IfType);
                        let name = unsafe { current.FriendlyName.to_string() }
                            .unwrap_or_else(|_| kind.to_string());
                        return Some(LinkInfo {
                            name,
                            kind: kind.to_string(),
                            wired,
                            direct: is_link_local(&address),
                            local_ip: address,
                            speed_mbps: current.ReceiveLinkSpeed / 1_000_000,
                        });
                    }
                }
                unicast = entry.Next;
            }
            adapter = current.Next;
        }
        None
    }

    unsafe fn socket_address_to_string(
        address: &windows::Win32::Networking::WinSock::SOCKET_ADDRESS,
    ) -> Option<String> {
        let sockaddr = address.lpSockaddr;
        if sockaddr.is_null() {
            return None;
        }
        match (*sockaddr).sa_family {
            windows::Win32::Networking::WinSock::AF_INET => {
                let v4 = &*(sockaddr as *const SOCKADDR_IN);
                let octets = v4.sin_addr.S_un.S_un_b;
                Some(format!("{}.{}.{}.{}", octets.s_b1, octets.s_b2, octets.s_b3, octets.s_b4))
            }
            windows::Win32::Networking::WinSock::AF_INET6 => {
                let v6 = &*(sockaddr as *const SOCKADDR_IN6);
                Some(std::net::Ipv6Addr::from(v6.sin6_addr.u.Byte).to_string())
            }
            _ => None,
        }
    }
}

#[cfg(target_os = "windows")]
pub use platform::describe;

#[cfg(not(target_os = "windows"))]
pub fn describe(_local_ip: std::net::IpAddr) -> Option<LinkInfo> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wifi(delay_ready: bool) -> LinkInfo {
        LinkInfo {
            name: "Wi-Fi".into(),
            kind: "Wi-Fi".into(),
            wired: false,
            local_ip: if delay_ready { "192.168.29.5".into() } else { "192.168.29.5".into() },
            speed_mbps: 780,
            direct: false,
        }
    }

    fn ethernet() -> LinkInfo {
        LinkInfo {
            name: "Ethernet".into(),
            kind: "Ethernet".into(),
            wired: true,
            local_ip: "169.254.10.2".into(),
            speed_mbps: 1000,
            direct: true,
        }
    }

    #[test]
    fn thunderbolt_and_usb4_count_as_wired() {
        // Both present as ETHERNET, which is the right answer: what matters is
        // that it is a cable, not which connector it uses.
        assert_eq!(classify(IF_TYPE_ETHERNET), ("Ethernet", true));
        assert_eq!(classify(IF_TYPE_WIFI), ("Wi-Fi", false));
    }

    #[test]
    fn unknown_interfaces_are_not_claimed_to_be_wired() {
        // Claiming a cable that is not there would suppress the one suggestion
        // worth making.
        let (_, wired) = classify(9999);
        assert!(!wired);
        assert!(!classify(IF_TYPE_TUNNEL).1);
    }

    #[test]
    fn link_local_addresses_mean_a_direct_cable() {
        assert!(is_link_local("169.254.10.2"));
        assert!(is_link_local("169.254.0.1"));
        // A normal LAN address is not a direct link.
        assert!(!is_link_local("192.168.29.8"));
        assert!(!is_link_local("169.255.10.2"));
        assert!(!is_link_local("169.254.10"), "needs all four octets");
    }

    #[test]
    fn a_wired_link_is_never_told_to_use_a_cable() {
        assert_eq!(suggestion(Some(&ethernet()), 500.0), None);
    }

    #[test]
    fn a_healthy_wireless_link_is_left_alone() {
        // Nagging a link that is behaving would train the user to ignore it.
        assert_eq!(suggestion(Some(&wifi(true)), 5.0), None);
        assert_eq!(suggestion(Some(&wifi(true)), 39.0), None);
    }

    #[test]
    fn a_struggling_wireless_link_gets_the_advice_once_it_is_true() {
        let advice = suggestion(Some(&wifi(true)), 85.0).expect("should advise");
        assert!(advice.contains("Wi-Fi"));
        assert!(advice.contains("85 ms"), "advice must quote the measured delay");
        assert!(advice.contains("cable"));
    }

    #[test]
    fn no_link_means_no_advice() {
        assert_eq!(suggestion(None, 900.0), None);
    }
}
