mod cloud;
use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::{
    io::{self, BufRead},
    net::UdpSocket,
    time::Duration,
};
type E = Box<dyn std::error::Error>;
fn hash(b: &[u8]) -> Vec<u8> {
    Md5::digest(b).to_vec()
}
fn field(k: &str) -> Option<(u64, u64)> {
    Some(match k {
        "power" => (2, 1),
        "mode" => (2, 2),
        "target" => (2, 4),
        "eco" => (2, 7),
        "sleep" => (2, 11),
        "fan" => (3, 2),
        "swing" => (3, 4),
        "room" => (4, 7),
        _ => return None,
    })
}
fn valid(k: &str, v: &Value) -> bool {
    match k {
        "power" | "eco" | "sleep" | "swing" => v.is_boolean(),
        "mode" => v.as_u64().is_some_and(|x| (2..=5).contains(&x)),
        "fan" => v.as_u64().is_some_and(|x| x <= 7),
        "target" => v
            .as_f64()
            .is_some_and(|x| (16.0..=31.0).contains(&x) && x * 2.0 == (x * 2.0).round()),
        _ => false,
    }
}
struct Device {
    socket: UdpSocket,
    token: Vec<u8>,
    header: Vec<u8>,
    key: Vec<u8>,
    iv: Vec<u8>,
    id: u32,
}
impl Device {
    fn new(ip: &str, token: &str) -> Result<Self, E> {
        let ip: std::net::Ipv4Addr = ip.parse().map_err(|_| "米家返回的设备地址无效")?;
        let token = hex::decode(token)?;
        if token.len() != 16 {
            return Err("设备凭据无效".into());
        }
        let socket = UdpSocket::bind("0.0.0.0:0")?;
        socket.connect((ip, 54321))?;
        socket.set_read_timeout(Some(Duration::from_secs(4)))?;
        let mut hello = vec![255; 32];
        hello[..4].copy_from_slice(&[0x21, 0x31, 0, 32]);
        socket.send(&hello)?;
        let mut b = [0u8; 4096];
        let n = socket.recv(&mut b).map_err(|_| {
            format!(
                "无法连接空调（{ip}）：局域网握手超时。请检查设备是否在线，以及 macOS 本地网络权限"
            )
        })?;
        if n != 32 || b[..4] != [0x21, 0x31, 0, 32] {
            return Err("握手响应无效".into());
        }
        let key = hash(&token);
        let iv = hash(&[key.as_slice(), token.as_slice()].concat());
        Ok(Self {
            socket,
            token,
            header: b[..16].to_vec(),
            key,
            iv,
            id: rand::random::<u16>() as u32,
        })
    }
    fn call(&mut self, method: &str, params: Value) -> Result<Value, E> {
        self.id += 1;
        let mut plain = serde_json::to_vec(&json!({"id":self.id,"method":method,"params":params}))?;
        plain.push(0);
        let enc = cbc::Encryptor::<aes::Aes128>::new_from_slices(&self.key, &self.iv)
            .map_err(|_| "加密失败")?
            .encrypt_padded_vec_mut::<Pkcs7>(&plain);
        let mut head = self.header.clone();
        head[4..8].fill(0);
        head[2..4].copy_from_slice(&((32 + enc.len()) as u16).to_be_bytes());
        let sig = hash(&[head.as_slice(), self.token.as_slice(), enc.as_slice()].concat());
        self.socket.send(&[head, sig, enc].concat())?;
        let mut buf = [0u8; 16384];
        let n = self.socket.recv(&mut buf).map_err(|_| {
            format!("空调已响应握手，但 {method} 查询超时；请重试或重新绑定设备凭据")
        })?;
        if n < 32
            || buf[..2] != [0x21, 0x31]
            || u16::from_be_bytes([buf[2], buf[3]]) as usize != n
            || buf[8..12] != self.header[8..12]
        {
            return Err("设备响应格式无效".into());
        }
        let expected = hash(&[&buf[..16], &self.token, &buf[32..n]].concat());
        if expected != buf[16..32] {
            return Err("设备凭据验证失败，请重新绑定".into());
        }
        let data = cbc::Decryptor::<aes::Aes128>::new_from_slices(&self.key, &self.iv)
            .map_err(|_| "解密失败")?
            .decrypt_padded_vec_mut::<Pkcs7>(&buf[32..n])
            .map_err(|_| "设备响应解密失败")?;
        let end = data.iter().rposition(|b| *b != 0).map_or(0, |i| i + 1);
        let data = &data[..end];
        let v: Value =
            serde_json::from_slice(data).map_err(|_| "空调响应已解密，但返回内容不是有效 JSON")?;
        if v["id"].as_u64() != Some(self.id as u64) || v.get("error").is_some() {
            return Err("设备未接受请求".into());
        }
        Ok(v["result"].clone())
    }
}
fn run(r: Value) -> Result<Value, E> {
    if r["op"] == "pair" {
        return cloud::pair(&r);
    }
    let mut d = Device::new(
        r["ip"].as_str().ok_or("缺少设备地址")?,
        r["token"].as_str().ok_or("请先绑定")?,
    )?;
    let info = d.call("miIO.info", json!([]))?;
    if info["model"] != "xiaomi.aircondition.c16"
        || info["mac"].as_str().unwrap_or("").to_lowercase()
            != r["mac"].as_str().unwrap_or("?").to_lowercase()
    {
        return Err("设备身份不匹配，请重新绑定".into());
    }
    if r["op"] == "set" {
        let k = r["key"].as_str().unwrap_or("");
        if !valid(k, &r["value"]) {
            return Err("不支持的控制值".into());
        }
        let (s, p) = field(k).ok_or("属性不存在")?;
        let result = d.call(
            "set_properties",
            json!([{"did":"ac","siid":s,"piid":p,"value":r["value"]}]),
        )?;
        if result
            .as_array()
            .is_none_or(|a| a.len() != 1 || a[0]["code"] != 0)
        {
            return Err("空调拒绝了此次设置".into());
        }
    } else if r["op"] != "read" {
        return Err("未知操作".into());
    }
    let keys = [
        "power", "mode", "target", "eco", "sleep", "fan", "swing", "room",
    ];
    let props: Vec<Value> = keys
        .iter()
        .map(|k| {
            let (s, p) = field(k).unwrap();
            json!({"did":k,"siid":s,"piid":p})
        })
        .collect();
    let result = d.call("get_properties", json!(props))?;
    let list = result.as_array().ok_or("状态响应无效")?;
    let mut state = serde_json::Map::new();
    for k in keys {
        let (s, p) = field(k).unwrap();
        let v = list
            .iter()
            .find(|v| v["siid"] == s && v["piid"] == p && v["code"] == 0)
            .map(|v| v["value"].clone())
            .unwrap_or(Value::Null);
        state.insert(k.into(), v);
    }
    for k in ["power", "mode", "target", "fan"] {
        if !valid(k, &state[k]) {
            return Err("设备状态不完整".into());
        }
    }
    Ok(json!({"state":state}))
}
fn main() {
    let line = io::stdin().lock().lines().next();
    let result = match line {
        Some(Ok(s)) => serde_json::from_str(&s)
            .map_err(|_| "请求格式错误".into())
            .and_then(run),
        _ => Err("缺少请求".into()),
    };
    match result {
        Ok(v) => println!("{}", v),
        Err(e) => {
            let msg = e.to_string();
            let safe = if msg.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)) {
                msg
            } else {
                "连接失败，请检查网络或重新绑定".into()
            };
            println!("{}", json!({"error":safe}))
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounds() {
        assert!(valid("target", &json!(26.5)));
        assert!(!valid("target", &json!(32)));
        assert!(!valid("target", &json!(26.2)));
        assert!(!valid("power", &json!(1)));
        assert!(!valid("room", &json!(20)));
        assert!(!valid("mode", &json!(1)));
    }
}

#[cfg(test)]
mod transport_tests {
    use super::*;
    fn exchange(corrupt: bool, wrong_id: bool) -> Result<Value, E> {
        let server = UdpSocket::bind("127.0.0.1:0")?;
        server.set_read_timeout(Some(Duration::from_secs(2)))?;
        let client = UdpSocket::bind("127.0.0.1:0")?;
        client.connect(server.local_addr()?)?;
        client.set_read_timeout(Some(Duration::from_secs(2)))?;
        let token = vec![0x11; 16];
        let key = hash(&token);
        let iv = hash(&[key.as_slice(), token.as_slice()].concat());
        let k = key.clone();
        let v = iv.clone();
        let t = token.clone();
        let worker = std::thread::spawn(move || {
            let mut b = [0u8; 4096];
            let (n, peer) = server.recv_from(&mut b).unwrap();
            assert_eq!(hash(&[&b[..16], &t, &b[32..n]].concat()), b[16..32]);
            let bytes = cbc::Decryptor::<aes::Aes128>::new_from_slices(&k, &v)
                .unwrap()
                .decrypt_padded_vec_mut::<Pkcs7>(&b[32..n])
                .unwrap();
            assert_eq!(bytes.last(), Some(&0));
            assert_eq!(&b[4..8], &[0, 0, 0, 0]);
            let request: Value = serde_json::from_slice(&bytes[..bytes.len() - 1]).unwrap();
            assert_eq!(request["method"], "get_properties");
            let response = json!({"id":request["id"].as_u64().unwrap()+u64::from(wrong_id),"result":[{"siid":2,"piid":1,"code":0,"value":false}]});
            let enc = cbc::Encryptor::<aes::Aes128>::new_from_slices(&k, &v)
                .unwrap()
                .encrypt_padded_vec_mut::<Pkcs7>(
                    &[response.to_string().as_bytes(), &[0, 0]].concat(),
                );
            let mut head = b[..16].to_vec();
            head[2..4].copy_from_slice(&((enc.len() + 32) as u16).to_be_bytes());
            let mut sig = hash(&[head.as_slice(), &t, &enc].concat());
            if corrupt {
                sig[0] ^= 1
            };
            server.send_to(&[head, sig, enc].concat(), peer).unwrap();
        });
        let mut header = vec![0; 16];
        header[..4].copy_from_slice(&[0x21, 0x31, 0, 32]);
        header[8..12].copy_from_slice(&42u32.to_be_bytes());
        let mut dev = Device {
            socket: client,
            token,
            header,
            key,
            iv,
            id: 10,
        };
        let result = dev.call("get_properties", json!([]));
        worker.join().unwrap();
        result
    }
    #[test]
    fn encrypted_udp_round_trip() {
        assert_eq!(exchange(false, false).unwrap()[0]["value"], false)
    }
    #[test]
    fn rejects_forged_checksum() {
        assert!(exchange(true, false).is_err())
    }
    #[test]
    fn rejects_unrelated_response() {
        assert!(exchange(false, true).is_err())
    }
}
