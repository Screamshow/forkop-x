"use strict";
"require baseclass";
"require form";
"require fs";
"require ui";
"require view.forkop.main as main";
const _ = main.translateForkop;

// Older native workers store Russian event messages. Translate those at the UI
// boundary as well, so existing history follows the selected interface language.
function nativeMessage(message) {
  let text = String(message || "");
  const messages = [
    ["Подключение к Tailscale", _("Connecting to Tailscale")],
    ["Соединение установлено", _("Connected")],
    ["Восстановление соединения", _("Reconnecting")],
    ["Соединение отключено", _("Disconnected")],
    ["Нативный Tailscale недоступен", _("Native Tailscale is unavailable")],
    ["Состояние неизвестно", _("Unknown status")],
    ["Ошибка подключения", _("Connection error")],
    ["Доступ к LAN разрешён", _("LAN access allowed")],
    ["Exit Node одобрен", _("Exit Node approved")],
    ["Exit Node ожидает одобрения", _("Exit Node awaiting approval")],
    ["Некорректный ключ Tailscale", _("Invalid Tailscale auth key")],
    ["Введите ключ Tailscale", _("Enter a Tailscale auth key")],
    ["Не удалось передать ключ", _("Failed to pass the auth key")],
    ["Не удалось определить локальную IPv4-сеть", _("Failed to determine the local IPv4 network")]
  ];
  for (const [russian, english] of messages) text = text.split(russian).join(english);
  return text;
}

function createTailscaleContent(section) {
  const option = section.option(form.DummyValue, "_native_tailscale");
  option.rawhtml = true;
  option.cfgvalue = () => {
    let busy = false, latest = {}, enteringNewKey = false;
    let statusGeneration = 0;
    const key = E("input", { type: "text", autocomplete: "off", style: "width:100%;max-width:480px" });
    const state = E("strong", {}, _("Checking status…"));
    const indicator = E("span", { "aria-hidden": "true", style: "width:10px;height:10px;border-radius:50%;background:#94a3b8;flex:none" });
    const status = E("span", { role: "status", "aria-live": "polite", style: "display:inline-flex;align-items:center;gap:9px;padding:6px 12px;border:1px solid currentColor;border-radius:999px;color:#94a3b8" }, [indicator, state]);
    function setStatus(text, kind) {
      const color = ({ connected: "#22c55e", disconnected: "#94a3b8", connecting: "#f59e0b", reconnecting: "#f59e0b", error: "#ef4444" })[kind] || "#94a3b8";
      state.textContent = text;
      status.style.color = color;
      indicator.style.backgroundColor = color;
    }
    const details = E("p");
    const transport = E("div", { style: "margin:16px 0;width:100%;max-width:100%;min-width:0;box-sizing:border-box" });
    const intro = E("p", {}, _("Enter an auth key for your Tailscale network."));
    const newKey = E("button", { type: "button", class: "cbi-button cbi-button-neutral", "aria-expanded": "false", style: "display:none" }, _("Enter a new auth key"));
    const keyRow = E("label", {}, [_("Auth key"), E("br"), key]);
    const logs = E("pre", { style: "max-height:240px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;margin-top:12px", "aria-live":"polite" }, _("No events yet."));
    const logPanel = E("details", { style:"margin-top:20px" }, [E("summary", { style:"cursor:pointer" }, _("Connection logs")), logs]);
    const connect = E("button", { type: "button", class: "cbi-button cbi-button-apply" }, _("Connect"));
    const disconnect = E("button", { type: "button", class: "cbi-button" }, _("Disconnect"));
    const ssh = E("input", { type: "checkbox" });
    const lan = E("input", { type: "checkbox" });
    const helpStyle = "margin:6px 0 0;font-size:13px;line-height:1.5;opacity:.75";
    const lanStatus = E("p", { style: helpStyle });
    const exitNode = E("input", { type: "checkbox" });
    const exitStatus = E("p", { style: helpStyle });
    const labels = { disconnected: _("Tailscale is disconnected"), connecting: _("Connecting to Tailscale…"), reconnecting: _("Reconnecting to Tailscale…"), connected: _("Router is connected to Tailscale"), error: _("Connection error"), unavailable: _("Native Tailscale is unavailable") };
    function render(data) {
      latest = data;
      const entries = Array.isArray(data.events) ? data.events : [];
      const text = entries.length ? entries.map(entry => "[" + new Date(entry.time * 1000).toLocaleString() + "] " + nativeMessage(entry.message)).join("\n") : _("No events yet.");
      if (logs.textContent !== text) { logs.textContent = text; logs.scrollTop = logs.scrollHeight; }
      setStatus(data.available ? (labels[data.state] || _("Unknown status")) : labels.unavailable, data.available ? data.state : "unavailable");
      details.textContent = nativeMessage(data.message) || (data.ip ? _("Router Tailscale address: ") + data.ip : "");
      const network = data.transport && data.transport.network;
      const paths = data.transport && data.transport.peers || [];
      transport.replaceChildren();
      transport.style.display = data.state === "connected" ? "" : "none";
      if (data.state === "connected") {
        transport.appendChild(E("strong", {}, _("Device connections")));
        if (paths.length) {
          const rows = paths.slice().sort((a, b) => String(a.name || (a.addresses || [])[0] || "").localeCompare(String(b.name || (b.addresses || [])[0] || ""))).map(peer => {
            const address = (peer.addresses || []).filter(ip => ip.indexOf(":") < 0).join(", ") || (peer.addresses || []).join(", ");
            const name = typeof peer.name === "string" ? peer.name.replace(/\.$/, "").split(".")[0] : "";
            const direct = peer.path === "direct", relayed = peer.path === "derp";
            const region = network && network.home_derp === peer.derp_region ? network.derp_region : _("region ") + peer.derp_region;
            return E("tr", {}, [
              E("td", { "data-label": _("Device"), style: "padding:14px 16px;overflow-wrap:anywhere" }, [E("strong", {}, name || _("Name unavailable")), E("div", { style: "font-size:13px;opacity:.75;margin-top:4px" }, address)]),
              E("td", { "data-label": _("Current path"), style: "padding:14px 16px" }, [E("strong", { style: "color:" + (direct ? "#22c55e" : relayed ? "#f59e0b" : "inherit") }, direct ? _("Direct") : relayed ? _("Via DERP") : _("Checking connection")), relayed ? E("div", { style: "font-size:12px;opacity:.75" }, region) : ""]),
              E("td", { "data-label": _("Latency"), style: "padding:14px 16px;white-space:nowrap" }, direct && peer.direct_rtt_ms != null ? peer.direct_rtt_ms + _(" ms") : "—"),
            ]);
          });
          transport.appendChild(E("div", { style: "width:100%;max-width:100%;overflow-x:auto;box-sizing:border-box" }, E("table", { class: "fkp-tailscale-peers", style: "width:100%;max-width:100%;table-layout:fixed;border-collapse:collapse;margin-top:8px;text-align:left" }, [
            E("thead", {}, E("tr", {}, [_("Device"), _("Current path"), _("Latency")].map(label => E("th", { style: "padding:12px 16px;font-weight:normal;opacity:.7" }, label)))),
            E("tbody", {}, rows),
          ])));
        } else transport.appendChild(E("p", {}, _("No device connections yet.")));
        if (network && network.derp_region) transport.appendChild(E("p", { style: "font-size:13px;opacity:.75;margin:8px 0 0" }, _("Inbound fallback: DERP · ") + network.derp_region + (network.derp_latency_ms != null ? " · " + network.derp_latency_ms + _(" ms") : "")));
      }
      const connected = data.state === "connected";
      const saved = Boolean(data.saved_identity);
      if (connected) key.value = "";
      if (connected || !saved) enteringNewKey = false;
      const needsKey = !saved || enteringNewKey;
      const readonly = main.isReadOnlyForkopView();
      intro.style.display = connect.style.display = connected ? "none" : "";
      intro.textContent = saved ? _("Device credentials are saved.") : _("Enter an auth key for your Tailscale network.");
      keyRow.style.display = !connected && needsKey ? "" : "none";
      newKey.style.display = !connected && saved && !readonly ? "" : "none";
      newKey.textContent = enteringNewKey ? _("Use saved credentials") : _("Enter a new auth key");
      newKey.setAttribute("aria-expanded", String(enteringNewKey));
      connect.textContent = needsKey ? _("Connect") : _("Reconnect using saved credentials");
      connect.disabled = readonly || busy || !data.available || connected || data.state === "connecting";
      newKey.disabled = connect.disabled;
      disconnect.disabled = readonly || busy || !data.available || data.state === "disconnected";
      key.disabled = readonly || busy || !data.available || data.state === "connected";
      ssh.disabled = readonly || busy || !data.ssh_available;
      ssh.title = data.ssh_available ? "" : _("Xrust 0.0.17 or later is required");
      ssh.checked = Boolean(data.ssh_enabled);
      lan.disabled = readonly || busy || !data.available;
      lan.checked = Boolean(data.lan_enabled);
      const routes = (data.lan_routes || []).join(", ");
      lanStatus.textContent = !data.lan_enabled ? "" : data.state !== "connected" ? _("LAN: waiting for connection.") : !data.lan_ready ? _("LAN: failed to configure access.") : data.routes_approved ? _("LAN: access allowed (") + routes + ")." : _("LAN: awaiting approval (") + routes + _("). In the Tailscale admin console: this router → Edit route settings → approve the route.");
      lanStatus.style.display = lanStatus.textContent ? "" : "none";
      exitNode.disabled = readonly || busy || !data.exit_available;
      exitNode.checked = Boolean(data.exit_enabled);
      exitStatus.textContent = !data.exit_enabled ? "" : !data.exit_available ? _("Exit Node is unavailable.") : data.state !== "connected" ? _("Exit Node: waiting for connection.") : !data.exit_ready ? _("Exit Node: failed to configure access.") : !data.exit_approved ? _("Exit Node: awaiting approval. In the Tailscale admin console: this router → Edit route settings → Use as exit node.") : "";
      exitStatus.style.display = exitStatus.textContent ? "" : "none";
    }
    async function request(action, args = []) {
      const result = action === "status" && main.isReadOnlyForkopView()
        ? await main.readForkopStatus("tailscale_native_status")
        : await fs.exec("/usr/bin/forkop", ["tailscale_native_" + action, ...args]);
      if (result.code !== 0) throw new Error(_("Tailscale action failed"));
      return JSON.parse(result.stdout);
    }
    async function refresh(isVisible = () => true) {
      if (busy || !root.isConnected) return;
      const generation = ++statusGeneration;
      const isCurrent = () => generation === statusGeneration && root.isConnected && isVisible();
      try {
        const data = await request("status");
        if (isCurrent()) render(data);
      } catch (error) {
        if (isCurrent()) setStatus(_("Failed to retrieve status"), "error");
      }
    }
    async function act(action, args = []) {
      if (busy || main.isReadOnlyForkopView()) return;
      const needsKey = action === "connect" && (!latest.saved_identity || enteringNewKey);
      const authKey = needsKey ? key.value.trim() : "";
      if (needsKey && !authKey) {
        ui.addNotification(null, E("p", {}, _("Enter a Tailscale auth key"))); return;
      }
      statusGeneration++;
      busy = true; render(latest);
      try {
        let data;
        if (action === "connect") {
          key.value = "";
          const response = await main.writeForkopUi("tailscale_connect", authKey);
          if (response.code !== 0) throw new Error(_("Tailscale action failed"));
          data = JSON.parse(response.stdout);
        } else {
          data = await request(action, args);
        }
        if (data.state === "error") ui.addNotification(null, E("p", {}, nativeMessage(data.message) || _("Failed to connect")));
        latest = data;
      } catch (error) {
        ui.addNotification(null, E("p", {}, error.message));
      } finally {
        busy = false;
        if (root.isConnected) render(latest);
        await refresh();
      }
    }
    newKey.addEventListener("click", () => {
      enteringNewKey = !enteringNewKey;
      if (!enteringNewKey) key.value = "";
      render(latest);
      if (enteringNewKey) key.focus();
    });
    connect.addEventListener("click", () => act("connect"));
    disconnect.addEventListener("click", () => act("disconnect"));
    ssh.addEventListener("change", () => act("ssh", [ssh.checked ? "1" : "0"]));
    lan.addEventListener("change", async function () {
      if (!lan.checked) return act("lan", ["0"]);
      lan.checked = Boolean(latest.lan_enabled);
      if (busy || main.isReadOnlyForkopView()) return;
      try {
        const preview = await request("lan", ["preview"]);
        if (!Array.isArray(preview.lan_preview_routes) || !preview.lan_preview_id)
          throw new Error(nativeMessage(preview.message) || _("Tailscale action failed"));
        ui.showModal(_("Allow LAN access"), [
          E("p", {}, _("Advertise these IPv4 networks through Tailscale?")),
          E("ul", {}, preview.lan_preview_routes.map((route) => E("li", {}, route))),
          E("div", { class: "right" }, [
            E("button", {
              type: "button",
              class: "cbi-button cbi-button-neutral",
              click: () => ui.hideModal(),
            }, _("Cancel")),
            E("button", {
              type: "button",
              class: "cbi-button cbi-button-apply",
              click: () => {
                ui.hideModal();
                void act("lan", ["1", preview.lan_preview_id]);
              },
            }, _("Allow LAN access")),
          ]),
        ]);
      } catch (error) {
        ui.addNotification(null, E("p", {}, error.message));
      }
    });
    exitNode.addEventListener("change", () => act("exit", [exitNode.checked ? "1" : "0"]));
    const root = E("div", { class: "cbi-section fkp-tailscale" }, [
      E("style", {}, `.fkp-tailscale { min-width:0; max-width:100%; box-sizing:border-box; overflow-wrap:anywhere; } #cbi-forkop-tailscale_native > h3 { display: none; } .fkp-tailscale-peers th, .fkp-tailscale-peers td { border-bottom:1px solid rgba(148,163,184,.25) !important; } .fkp-tailscale-peers tbody tr:last-child td:last-child { border-bottom:0 !important; }
@media (max-width:700px) {
 .fkp-tailscale-peers, .fkp-tailscale-peers tbody, .fkp-tailscale-peers tr { display:block; width:100%; min-width:0; }
 .fkp-tailscale-peers thead { display:none; }
 .fkp-tailscale-peers tr { border:1px solid rgba(148,163,184,.25); margin-bottom:10px; box-sizing:border-box; }
 .fkp-tailscale-peers td { display:block; width:auto !important; padding:8px 12px !important; white-space:normal !important; overflow-wrap:anywhere; }
 .fkp-tailscale-peers td::before { content:attr(data-label); display:block; font-size:12px; opacity:.7; margin-bottom:3px; }
 .fkp-tailscale > div, .fkp-tailscale [role="status"] { min-width:0; max-width:100%; box-sizing:border-box; }
}
`),
      E("div", { style: "display:flex;flex-direction:column;align-items:flex-start;gap:16px;margin:0 0 12px" }, [E("h3", { style: "margin:0;padding:0" }, _("Remote access")), status]),
      intro,
      details, transport,
      keyRow,
      E("p", { style: "display:flex;gap:12px;flex-wrap:wrap;margin-top:16px" }, [connect, newKey, disconnect]),
      E("hr"),
      E("div", { style: "margin:14px 0" }, E("label", { style: "display:inline-flex;align-items:center;gap:8px", title: _("Allow SSH access to this router through Tailscale on port 22.") }, [ssh, _("Allow SSH")])),
      E("div", { style: "margin:14px 0" }, [E("label", { style: "display:inline-flex;align-items:center;gap:8px" }, [lan, _("Allow LAN access")]), lanStatus]),
      E("div", { style: "margin:14px 0" }, [E("label", { style: "display:inline-flex;align-items:center;gap:8px", title: _("Allow devices on your tailnet to access the internet through this router and Forkop rules. LAN and SSH access are enabled separately.") }, [exitNode, _("Use this router as an Exit Node")]), exitStatus]),
      logPanel,
    ]);
    main.pollLuciTab(root, refresh, 3000);
    return root;
  };
}
return baseclass.extend({ createTailscaleContent });
