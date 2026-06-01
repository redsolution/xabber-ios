# XMPP c2s Endpoint Resolution

## Client Behavior

- Manual account host/port is an explicit override and bypasses SRV lookup.
- Automatic mode resolves `_xmpp-client._tcp.<xmpp-domain>` with the device system DNS resolver first.
- SRV records are tried by RFC 2782 priority/weight order.
- If no SRV response is available, the client falls back to `<xmpp-domain>:5222`.
- If SRV returns target `.`, the service is unavailable and the client must not fall back.
- DoH/DoT/DoU must not be hidden production defaults. They are explicit opt-in or controlled fallback only.
- XEP-0156 host-meta/WebSocket discovery is separate from native TCP c2s and is not used by this path.

## Production DNS

For each production XMPP origin domain:

```dns
_xmpp-client._tcp.example.com. 300 IN SRV 10 10 5222 xmpp1.example.com.
xmpp1.example.com.             300 IN A    203.0.113.10
xmpp1.example.com.             300 IN AAAA 2001:db8::10
```

Keep A/AAAA on the origin domain only if direct fallback is intended when SRV is absent:

```dns
example.com. 300 IN A    203.0.113.10
example.com. 300 IN AAAA 2001:db8::10
```

## TLS And STARTTLS

- Native c2s uses TCP port `5222` with STARTTLS.
- TLS validation must use the XMPP origin domain as the reference identity even when the TCP connection host is an SRV target.
- Certificates should contain DNS-ID for the origin domain and ideally SRV-ID `_xmpp-client.<domain>`.
- SNI/reference identity should be the origin domain, not the SRV target host.

## ejabberd Notes

- `/Users/igor.boldin/projects/xabber/server/config/ejabberd.yml` has a c2s listener on `5222`, with `starttls` and listener `certfile` shown as deployment options.
- `/Users/igor.boldin/projects/xabber/server/ejabberd.yml.example` has a c2s listener on `5222` with `starttls: true`.
- `/Users/igor.boldin/projects/xabber/server/src/ejabberd_c2s.erl` obtains domain certificates through `ejabberd_pkix:get_certfile/1` when no listener certfile is set.
- Listener `certfile` is treated as deprecated in this server code; prefer global/domain `certfiles` deployment configuration.
