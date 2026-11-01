let recovery = require("singbox.subscription_recovery");
let checks = 0;
function expect(value, message) { if (!value) die("FAIL: " + message); checks++; }
function fixture() {
    return { config: { outbounds: [
        {type:"vless",tag:"bad"}, {type:"vless",tag:"good"},
        {type:"vless",tag:"dependent",detour:"bad"},
        {type:"selector",tag:"section",outbounds:["bad","dependent","good"],default:"bad"}
    ], route:{final:"section"}}, states:[{
        subscriptionOutbounds:{bad:true,good:true,dependent:true},
        outboundMetadata:{names:{bad:"Bad",good:"Good",dependent:"Dependent"}},
        links:{bad:"private link",good:"good link"}
    }]};
}
let f=fixture(); let before=sprintf("%J",f);
let rejected={status:1,output:"reload-plan: candidate configuration rejected"};
expect(recovery.cold_retry(rejected,f.states),"old core rejection uses guarded cold check");
expect(!recovery.cold_retry(rejected,[]),"manual-only plan remains rejected");
expect(!recovery.cold_retry({status:0,output:rejected.output},f.states),"successful hot plan stays hot");
expect(!recovery.cold_retry({status:1,output:"permission denied"},f.states),"binary failure is not repaired");
expect(recovery.blamed_index("FATAL[0000] initialize outbound[3]: transport refused") === 3,"Go initialization path");
expect(recovery.blamed_index("WARN[0000] initialize outbound[3]: dial failed") == null,"runtime warning refused");
let result=recovery.recover(f.config,f.states,"check: outbounds[0].transport.session_length: invalid");
expect(result != null,"identified subscription node repaired");
expect(sprintf("%J",f)==before,"inputs untouched");
expect(length(result.config.outbounds)==2,"detour dependent removed");
expect(result.config.outbounds[1].default=="good","default points at retained member");
expect(length(result.config.outbounds[1].outbounds)==1,"group pruned");
expect(result.states[0].links.bad==null,"removed link not published");
expect(length(result.states[0].skippedSubscriptionOutbounds)==2,"reasons retained");
expect(result.states[0].outboundMetadata.names.good=="Good","valid metadata retained");
expect(recovery.recover(f.config,f.states,"TLS outbounds[0].transport timeout")==null,"network message is not a validation path");
expect(recovery.recover(f.config,f.states,"check: outbounds[99].type: invalid")==null,"index bounds");
f.states[0].subscriptionOutbounds={};
expect(recovery.recover(f.config,f.states,"check: outbounds[0].type: invalid")==null,"manual node preserved");
f=fixture(); f.config.outbounds[3].outbounds=["bad","dependent"];
expect(recovery.recover(f.config,f.states,"outbounds[0].type: invalid")==null,"empty section fails closed");
f=fixture(); f.config.outbounds[3].outbounds=["bad","direct"];
push(f.config.outbounds,{type:"direct",tag:"direct"});
expect(recovery.recover(f.config,f.states,"outbounds[0].type: invalid")==null,"direct-only fallback refused");
f=fixture(); delete f.states[0].subscriptionOutbounds.dependent;
expect(recovery.recover(f.config,f.states,"outbounds[0].type: invalid")==null,"manual detour dependency preserved");
f=fixture(); f.config.route.rules=[{outbound:"bad"}];
expect(recovery.recover(f.config,f.states,"outbounds[0].type: invalid")==null,"direct route reference refused");
print("Subscription recovery: ",checks," checks passed\n");
