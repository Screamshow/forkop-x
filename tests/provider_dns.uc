let provider = require('xrust.provider_dns');
function check(value, message) { if (!value) die(message + '\n'); }
let dump = { interface: [
    { interface:'lan', up:true, l3_device:'br-lan', 'dns-server':['192.168.1.1'], route:[] },
    { interface:'wanb', up:true, metric:3, l3_device:'eth2', 'dns-server':['10.2.0.1'], route:[{target:'0.0.0.0',mask:0}] },
    { interface:'wan', up:true, metric:1, l3_device:'eth1', 'dns-server':['10.1.0.1','10.1.0.2','bad'], route:[{target:'0.0.0.0',mask:0}] }
] };
let rules = [
    { iif:'eth1',table:'1' }, { table:'1',fwmark:'0x100',fwmask:'0x3f00' },
    { iif:'eth2',table:'2' }, { table:'2',fwmark:'0x200',fwmask:'0x3f00' }
];
let selected = provider.select_candidates(dump,rules,[],{wan:'online',wanb:'online'});
check(length(selected)==3 && selected[0].server=='10.1.0.1' && selected[2].mark==512,'order/mark/filter');
selected=provider.select_candidates(dump,rules,[],{wan:'offline',wanb:'online'});
check(length(selected)==1 && selected[0].interface=='wanb','mwan offline exclusion');
check(length(provider.select_candidates(dump,[],[],{wan:'online',wanb:'online'}))==0,'missing policy routing must not leak');
check(length(provider.select_candidates(dump,[],[],{}))==3,'plain WAN works without mwan');
check(length(provider.select_candidates(dump,rules,[],{wan:'offline',wanb:'offline'}))==0,'no public fallback');
print('provider DNS selection checks passed\n');
let renamed = { interface: [
 { interface:'internet_fiber',up:true,metric:1,l3_device:'pppoe-uplink',
   'dns-server':['10.3.0.1'],route:[{target:'0.0.0.0',mask:0}] },
 { interface:'backup.4g',up:true,metric:9,l3_device:'wwan0',
   'dns-server':['10.4.0.1'],route:[{target:'0.0.0.0',mask:0}] }
] };
let custom_rules=[{iif:'pppoe-uplink',table:'17'},{table:'17',fwmark:'0x4000',fwmask:'0xfc000'},
 {iif:'wwan0',table:'23'},{table:'23',fwmark:'0x8000',fwmask:'0xfc000'}];
let custom=provider.select_candidates(renamed,custom_rules,[],{'internet_fiber':'online','backup.4g':'online'});
check(length(custom)==2 && custom[0].device=='pppoe-uplink' && custom[0].mark==16384 &&
 custom[1].interface=='backup.4g' && custom[1].mark==32768,'custom names/tables/mwan mask');
custom=provider.select_candidates(renamed,custom_rules,[],{'internet_fiber':'offline','backup.4g':'online'});
check(length(custom)==1 && custom[0].interface=='backup.4g','custom-name failover');
print('custom interface names and policy tables checks passed\n');
let fs = require('fs');
fs.popen = function(command, mode) {
    let value = index(command, 'network.interface dump') >= 0 ? dump :
        (index(command, '/usr/libexec/ip-full -4') >= 0 ? rules : []);
    // BusyBox ip cannot supply JSON rules; ip-full must be tried first.
    let status = index(command, 'ip -4') == 0 ? 1 : 0;
    return { read:function() { return sprintf('%J',value); }, close:function() { return status; } };
};
fs.readfile = function(path) {
    if (index(path,'iface_state/wanb') >= 0) return 'online\n';
    if (index(path,'iface_state/wan') >= 0) return 'online\n';
    return null;
};
let dns=require('xrust.dns');
let settings={ dns_use_provider:'1',dns_type:'doh',dns_server:['8.8.8.8'],
    bootstrap_dns_server:['1.1.1.1'],dns_detour_enabled:'1',dns_detour_section:'proxy' };
let config=dns.config(settings);
check(!config.unsupported && config.state.dns_type=='udp','provider UDP overrides preserved protocol');
check(config.servers[1].server=='10.1.0.1' && config.servers[1].detour=='provider-dns-wan-eth1-100','canonical DNS direct detour');
check(length(config.outbounds)==2 && config.outbounds[1].routing_mark==512,'generated WAN outbounds');
let state=dns.state_template(settings);
state.main_index=2;
let candidate=dns.server_config(settings,state);
check(candidate.server=='10.2.0.1' && candidate.detour=='provider-dns-wan-eth2-200','DNS failover keeps correct WAN');
check(settings.dns_server[0]=='8.8.8.8' && settings.dns_type=='doh','manual settings preserved');
settings.dns_use_provider='0';
check(dns.server_config(settings).server=='8.8.8.8','manual mode restoration');
let manual_config=dns.config(settings);
check(sprintf('%J',manual_config.inbounds)==sprintf('%J',config.inbounds),'toggle keeps identical listeners');
check(sprintf('%J',manual_config.sniff_inbounds)==sprintf('%J',config.sniff_inbounds),'toggle keeps DNS hijack inputs');
let overridden = !!getenv("FORKOP_DNS_HEALTH_ADDRESS");
check(length(manual_config.inbounds)==(overridden ? 17 : 1),'bounded stable health listener layout');
let candidate_probe = dns.health_probe("main", 2, config.state);
check(candidate_probe.source == (overridden ? "" : "127.16.0.3"),'candidate probe follows the applied layout');
settings.dns_server=['8.8.8.8','9.9.9.9'];
check(sprintf('%J',dns.config(settings).inbounds)==sprintf('%J',config.inbounds),'manual DNS count keeps listeners');
settings.dns_use_provider='1';
// Carrier and default routes stay up: only mwan3's health state changes.
fs.readfile=function(path){
 if(index(path,'iface_state/wanb')>=0)return 'online\n';
 if(index(path,'iface_state/wan')>=0)return 'offline\n';
 return null;
};
let degraded=dns.config(settings);
check(degraded.state.main_servers[0]=='10.2.0.1','silent upstream failure selects healthy WAN');
check(degraded.servers[1].detour=='provider-dns-wan-eth2-200' && degraded.outbounds[0].routing_mark==512,
 'silent failure uses backup mark and binding');
check(!dns.state_matches(config.state,degraded.state),'worker detects health-state-only change');
check(sprintf('%J',degraded.inbounds)==sprintf('%J',config.inbounds),'silent failure preserves listener layout');
fs.readfile=function(path){return index(path,'iface_state/')>=0?'online\n':null;};
let restored=dns.config(settings);
check(restored.state.main_servers[0]=='10.1.0.1' && !dns.state_matches(degraded.state,restored.state),
 'primary recovery is detected and preferred');
check(sprintf('%J',restored.inbounds)==sprintf('%J',degraded.inbounds),'recovery preserves listener layout');
fs.readfile=function(path){return 'offline\n';};
check(dns.config(settings).unsupported != null,'no WAN fails explicitly');
fs.readfile=function(path){return index(path,'iface_state/')>=0?'online\n':null;};
dump.interface[2]['dns-server']=['10.1.1.53'];
dump.interface[2].l3_device='pppoe-renewed';
rules[0].iif='pppoe-renewed';
let renewed=dns.config(settings);
check(renewed.state.main_servers[0]=='10.1.1.53','DHCP/PPPoE refreshed DNS discovered');
check(renewed.outbounds[0].bind_interface=='pppoe-renewed' && renewed.outbounds[0].routing_mark==256,
 'PPPoE recreated device binding refreshed');
check(!dns.state_matches(restored.state,renewed.state),'lease renewal schedules regeneration');
check(sprintf('%J',renewed.inbounds)==sprintf('%J',restored.inbounds),'renewal preserves listeners');
print('provider DNS configuration and restoration checks passed\n');
print('carrier-up mwan3 offline/recovery configuration checks passed\n');
print('DHCP/PPPoE DNS and device renewal checks passed\n');

push(dump.interface[2]['dns-server'], '2001:db8::53');
let selected_dual_stack = provider.select_candidates(dump, rules, [
    { iif:'pppoe-renewed', table:'3' }, { table:'3', fwmark:'0x300', fwmask:'0x3f00' }
], {wan:'online'});
let dual = dns.config_from_state({ ...renewed.state, provider_routes: selected_dual_stack,
    main_servers: map(selected_dual_stack, route => route.server),
    bootstrap_servers: map(selected_dual_stack, route => route.server), main_index: 1, bootstrap_index: 0 });
let v4_bind = filter(dual.outbounds, outbound => outbound.tag == dual.servers[0].detour)[0];
let v6_bind = filter(dual.outbounds, outbound => outbound.tag == dual.servers[1].detour)[0];
check(v4_bind.bind_interface == v6_bind.bind_interface && v4_bind.routing_mark == 256 &&
    v6_bind.routing_mark == 768, 'address families on the same device must retain their own routing marks');
print('provider DNS keeps separate IPv4 and IPv6 marks on one device\n');
