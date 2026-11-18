<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<!-- ResolvGuard WebUI Integration v1 -->
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge" />
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta http-equiv="Pragma" content="no-cache" />
<title>ResolvGuard - DNS Health</title>
<link rel="shortcut icon" href="images/favicon.png" />
<link rel="stylesheet" type="text/css" href="index_style.css" />
<link rel="stylesheet" type="text/css" href="form_style.css" />
<script type="text/javascript" src="/js/jquery.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/client_function.js"></script>
<script type="text/javascript" src="/validator.js"></script>
<style type="text/css">
/* Keep ASUS navigation and page chrome; isolate the embedded dashboard in an about:srcdoc iframe. */
#rg-native-panel { background:#101d24; border:1px solid #294048; border-radius:14px; overflow:hidden; width:100%; min-height:560px; }
#rg-native-panel iframe { display:block; width:100%; height:1350px; border:0; background:#091016; }
#rg-shell-title { color:#eff5f5; padding:14px 18px 0; background:#101d24; font-size:17px; font-weight:bold; }
#rg-shell-subtitle { padding:4px 18px 10px; background:#101d24; color:#9ab3b9; font-size:12px; }
#rg-native-host { padding:8px; background:#26353a; }
</style>
<script type="text/javascript">
function rgRequestManualCheck() {
  var form=document.getElementById("rg_manual_form");
  if (!form || !form.elements.namedItem("action_script")) return false;
  // A no-navigation action: ASUS may redirect to current_page after applying.
  form.elements.namedItem("current_page").value="";
  // Submit only on an explicit click, never during dashboard initialization.
  form.elements.namedItem("next_page").value="";
  form.submit();
  return true;
}
// Use the same firmware-native custom settings transport as MerlinAU:
// fixed service action name, separate namespaced data, preserve other add-ons.
var rgSharedCustomSettings = <% get_custom_settings(); %>;
function rgRequestConfiguration(data) {
  var form=document.getElementById('rg_config_form');
  if(!form || typeof data!=='string' || data.length>560 || !/^[A-Za-z0-9_.:/|_-]+$/.test(data)) return false;
  if(!rgSharedCustomSettings || typeof rgSharedCustomSettings!=='object' || Array.isArray(rgSharedCustomSettings)) return false;
  // The shell accepts only this validated, bounded ASCII data. MerlinAU's
  // amng_custom mechanism can transport it directly, without a base64 tool.
  var merged=Object.create(null);
  Object.keys(rgSharedCustomSettings).forEach(function(key){
    if(key!=='ResolvGuard_config_request') merged[key]=rgSharedCustomSettings[key];
  });
  merged.ResolvGuard_config_request=data;
  // No firmware redirect on a configuration save.
  form.elements.namedItem('current_page').value='';
  form.elements.namedItem('next_page').value='';
  form.elements.namedItem('action_script').value='start_ResolvGuardCfg';
  form.elements.namedItem('amng_custom').value=JSON.stringify(merged);
  form.submit();
  // Keep subsequent saves from this open page in sync with the submitted key.
  rgSharedCustomSettings.ResolvGuard_config_request=data;
  return true;
}
// MerlinAU dismisses the ASUS apply overlay after handling its result.
// A failed or timed-out ResolvGuard request must also release this overlay.
function rgFinishConfiguration() {
  try { if (typeof hideLoading === 'function') hideLoading(); } catch(e) {}
  var overlay=document.getElementById('Loading');
  if (overlay) overlay.style.display='none';
}
function initial() {
  if (typeof show_menu === 'function') show_menu();
  rgLoadEmbedded();
}
function rgLoadEmbedded() {
  var frame=document.getElementById('rg_dashboard');
  var template=document.getElementById('rg_inline_dashboard');
  if (!frame || !template || frame.getAttribute('data-rg-loaded')==='1') return;
  frame.setAttribute('data-rg-loaded','1');
  /* about:srcdoc inherits the authenticated parent origin, so the manual
     service-action bridge and /ext/ResolvGuard JSON feeds keep working. */
  frame.srcdoc='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body>'+template.innerHTML+'</body></html>';
}
function rgAdjustHeight() {
  var frame=document.getElementById('rg_dashboard');
  if(!frame) return;
  try {
    var doc=frame.contentDocument || frame.contentWindow.document;
    if(!doc || !doc.body || !doc.documentElement) return;
    /* Use actual content height, never the iframe viewport height;
       including documentElement.scrollHeight causes a resize feedback loop. */
    var app=doc.querySelector('.app');
    var appHeight=app?Math.ceil(app.getBoundingClientRect().height):0;
    var size=Math.max(doc.body.scrollHeight,appHeight,600)+8;
    if(Math.abs(frame.offsetHeight-size)>8) frame.style.height=size+'px';
  } catch(e) { /* Fixed-height fallback if browser denies frame measurement. */ }
}
function rgDashboardLoaded() {
  rgAdjustHeight();
  try {
    var doc=document.getElementById('rg_dashboard').contentDocument;
    if(typeof ResizeObserver!=='undefined' && doc && doc.body) {
      var observer=new ResizeObserver(rgAdjustHeight);
      observer.observe(doc.body);
    }
  } catch(e) { /* Fallback remains scrollable in frame. */ }
  setTimeout(rgAdjustHeight,500);
  setTimeout(rgAdjustHeight,1500);
}
</script>
</head>
<body class="bg" onload="initial();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<table class="content" cellpadding="0" cellspacing="0" style="margin:0 auto;">
<tr><td width="17">&nbsp;</td><td width="202" valign="top">
<div id="mainMenu"></div><div id="subMenu"></div>
</td><td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<table width="98%" border="0" cellpadding="0" cellspacing="0">
<tr><td valign="top">
<table width="760px" cellpadding="4" cellspacing="0" class="FormTitle">
<tbody><tr><td valign="top" id="rg-native-host">
<div id="rg-native-panel">
  <div id="rg-shell-title">ResolvGuard — DNS Health Dashboard</div>
  <div id="rg-shell-subtitle">DNS reliability monitoring and independent health checks</div>
  <iframe id="rg_dashboard" title="ResolvGuard dashboard" scrolling="auto" onload="rgDashboardLoaded()"></iframe>
</div>
</td></tr></tbody></table>
</td></tr></table>
</td><td width="10"></td></tr></table>
<!-- The embedded dashboard cannot execute shell code or send arbitrary commands.
     Use the exact hidden_frame identity expected by ASUS start_apply.htm
     and MerlinAU; an arbitrary iframe name can trigger firmware redirects. -->
<iframe name="hidden_frame" id="hidden_frame" title="ResolvGuard command response" style="display:none;width:0;height:0;border:0" aria-hidden="true"></iframe>
<form id="rg_manual_form" method="post" action="start_apply.htm" target="hidden_frame" style="display:none">
  <input type="hidden" name="action_script" value="start_ResolvGuardManualCheck" />
  <input type="hidden" name="action_mode" value="apply" />
  <input type="hidden" name="action_wait" value="0" />
  <input type="hidden" name="current_page" value="" />
  <input type="hidden" name="next_page" value="" />
  <input type="hidden" name="modified" value="0" />
</form>
<form id="rg_config_form" name="form" method="post" action="start_apply.htm" target="hidden_frame" style="display:none">
  <input type="hidden" name="action_script" value="" />
  <input type="hidden" name="amng_custom" value="" />
  <input type="hidden" name="action_mode" value="apply" />
  <input type="hidden" name="action_wait" value="10" />
  <input type="hidden" name="current_page" value="" />
  <input type="hidden" name="next_page" value="" />
  <input type="hidden" name="modified" value="0" />
</form>
<div id="footer"></div>

<template id="rg_inline_dashboard">
<style>
:root{--bg:#091016;--panel:#111d24;--panel2:#16262d;--line:#294048;--sub:#91a8b1;--text:#edf6f5;--green:#63e8b6;--green2:#1c9c76;--amber:#ffbd69;--red:#ff817e;--blue:#93c8f9;--muted:#506a72;--shadow:0 14px 60px #02090d70;font-family:Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{background:var(--bg);color:var(--text);margin:0;min-height:100vh;font-size:14px;line-height:1.45}button,select{font:inherit}button{cursor:pointer}button:focus-visible,select:focus-visible{outline:2px solid var(--green);outline-offset:3px}svg{display:block}.app{min-height:100vh;display:flex}.sidebar{width:245px;flex-shrink:0;border-right:1px solid #21353e;background:#0b151b;display:flex;flex-direction:column;position:sticky;top:0;height:100vh;padding:24px 15px 16px}.logo{display:flex;align-items:center;gap:12px;padding:2px 10px 30px}.logo-mark{display:grid;place-items:center;width:43px;height:43px;border-radius:14px;background:linear-gradient(155deg,#3cd9a1,#09614e);box-shadow:0 3px 26px #1fa77b38}.logo-mark svg{width:28px;height:28px}.brand{font-size:19px;font-weight:800;letter-spacing:-.75px;line-height:1.05}.brand-sub{font-size:10px;letter-spacing:1.6px;text-transform:uppercase;color:#799a9b;margin-top:5px;font-weight:700}.side-section{font-size:10px;color:#607f88;letter-spacing:1.7px;font-weight:800;text-transform:uppercase;padding:0 15px;margin:7px 0 10px}.nav{width:100%;border:0;background:transparent;color:#94aeb5;text-align:left;padding:12px 15px;display:flex;align-items:center;gap:12px;border-radius:11px;margin:2px 0;transition:.18s}.nav svg{height:18px;width:18px}.nav:hover{background:#17282f;color:var(--text)}.nav.active{background:#1a3937;color:#abffda;font-weight:750;box-shadow:inset 3px 0 var(--green)}.side-bottom{margin-top:auto;border-top:1px solid var(--line);padding:17px 10px 0}.small-pill{border:1px solid #34634e;border-radius:100px;color:#a9f0d1;padding:5px 10px;background:#133026;display:inline-flex;align-items:center;gap:7px;font-size:11px;font-weight:700}.dot{display:inline-block;width:7px;height:7px;background:var(--green);border-radius:50%;box-shadow:0 0 0 3px #63e8b61d}.small-note{font-size:11px;color:#6b8991;line-height:1.65;margin-top:12px}.main{width:calc(100% - 245px);max-width:1640px;margin:0 auto;padding:25px 39px 55px}.top{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;margin-bottom:25px}.eyebrow{letter-spacing:1.7px;text-transform:uppercase;color:#83aaac;font-size:11px;font-weight:800}.page-title{font-size:30px;letter-spacing:-1.2px;font-weight:800;margin:4px 0 3px}.desc{color:var(--sub);font-size:13px}.top-tools{display:flex;gap:9px;align-items:center;flex-wrap:wrap;justify-content:flex-end}.tag{padding:7px 11px;border:1px solid #2b4a52;border-radius:9px;color:#92b3b9;font-size:11px;font-weight:750;background:#11232b;white-space:nowrap}.tag.demo{color:#ffe2a4;background:#2b251c;border-color:#61502c}.btn{border-radius:10px;background:#1b3038;color:#e8f7f4;border:1px solid #38535c;padding:10px 14px;display:inline-flex;gap:8px;align-items:center;justify-content:center;font-weight:750;transition:.17s;white-space:nowrap}.btn:hover{filter:brightness(1.17);transform:translateY(-1px)}.btn svg{width:16px;height:16px}.btn.primary{background:var(--green);border-color:var(--green);color:#073026}.btn:disabled{opacity:.48;cursor:not-allowed;transform:none}.hero{background:radial-gradient(ellipse at 84% 14%,#1d77544d,transparent 48%),linear-gradient(115deg,#142b2b,#12212a 72%);border:1px solid #29564b;border-radius:20px;min-height:252px;padding:30px 32px;display:grid;grid-template-columns:1.25fr .8fr;gap:24px;align-items:center;overflow:hidden;position:relative}.hero:after{content:"";position:absolute;border:1px solid #5cd9a41b;border-radius:50%;width:420px;height:420px;right:-90px;top:-140px;pointer-events:none}.hero-kicker{font-size:11px;letter-spacing:1.7px;color:#9adbc5;font-weight:800;text-transform:uppercase;display:flex;align-items:center;gap:9px}.hero h2{font-size:37px;line-height:1.13;letter-spacing:-1.4px;margin:18px 0 9px;max-width:600px}.hero p{color:#b1c7c7;font-size:13px;max-width:510px;margin:0}.hero-meta{display:flex;flex-wrap:wrap;gap:8px;margin-top:22px}.hero-meta span{font-size:11px;border:1px solid #395952;border-radius:100px;padding:7px 11px;color:#b4e1d0;background:#14332d}.heartbeat{position:relative;z-index:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:7px;padding:8px 4px}.heart-ring{width:129px;height:129px;border:1px solid #3b97785c;border-radius:50%;display:grid;place-items:center;background:#0d2b27a6;box-shadow:0 0 0 13px #43b18c0d,0 0 0 29px #43b18c06;position:relative}.heart-ring:after{content:"";position:absolute;inset:16px;border:1px dashed #9bf6c42c;border-radius:50%}.heart-ring svg{width:57px;height:57px;color:var(--green);position:relative;z-index:1}.heart-ring.pulse{animation:ring-pulse 1.5s ease-out}.heart-ring.pulse svg{animation:icon-pulse 1.5s ease-out}@keyframes ring-pulse{0%{box-shadow:0 0 0 4px #43b18c33,0 0 0 8px #43b18c22}60%{box-shadow:0 0 0 22px #43b18c0f,0 0 0 44px #43b18c00}100%{box-shadow:0 0 0 13px #43b18c0d,0 0 0 29px #43b18c06}}@keyframes icon-pulse{0%,100%{transform:scale(1)}22%{transform:scale(1.17)}45%{transform:scale(.95)}}.heartbeat.running .heart-ring svg{animation:icon-pulse .85s infinite}.heartbeat.running .heart-ring{border-color:#cfad55}.heart-detail{color:#e4f6ef;font-weight:800;margin-top:13px}.heartbeat small{color:#8db2ae;font-size:11px}.ecg{width:185px;height:35px;margin-top:1px}.ecg path{fill:none;stroke:var(--green);stroke-linejoin:round;stroke-linecap:round;stroke-width:2}.section-head{display:flex;align-items:center;justify-content:space-between;gap:14px;margin:25px 0 14px}.section-head h3{font-size:15px;letter-spacing:-.3px;margin:0;font-weight:800}.hint{color:#7e9ba3;font-size:11px}.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}.stat{background:var(--panel);border:1px solid #2b4149;border-radius:15px;padding:17px 18px;min-height:112px}.stat-label{font-size:11px;color:#92b1b7;display:flex;align-items:center;gap:8px}.stat-label svg{width:15px;height:15px}.stat-val{font-size:27px;font-weight:800;letter-spacing:-1px;margin-top:10px}.stat-sub{font-size:11px;color:#819da5;margin-top:3px}.green{color:var(--green)!important}.amber{color:var(--amber)!important}.red{color:var(--red)!important}.blue{color:var(--blue)!important}.two-col{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(295px,.95fr);gap:16px}.card{background:var(--panel);border:1px solid #2b424a;border-radius:16px;box-shadow:0 10px 26px #00000013;overflow:hidden}.card-pad{padding:20px}.card-head{display:flex;align-items:center;justify-content:space-between;padding:20px 21px 13px;gap:12px}.card-title{font-weight:800;font-size:14px;letter-spacing:-.2px}.card-sub{font-size:11px;color:#84a0a7;margin-top:3px}.text-link{border:0;background:none;color:#85eabf;font-size:11px;font-weight:750;padding:6px;white-space:nowrap}.text-link:hover{text-decoration:underline}.resolve-row{display:flex;align-items:center;gap:12px;justify-content:space-between;padding:15px 21px;border-top:1px solid #223841;background:transparent;width:100%;color:inherit;text-align:left}.resolve-row:hover{background:#182b33}.res-left{display:flex;gap:12px;align-items:center;min-width:0}.status-glyph{height:35px;width:35px;background:#143b32;border-radius:11px;display:grid;place-items:center;color:var(--green);flex-shrink:0}.status-glyph.bad{background:#493026;color:var(--red)}.res-name{font-weight:750;font-size:13px}.res-ip{color:#80a0a7;font-size:11px;font-family:ui-monospace,Consolas,monospace;margin-top:3px}.res-right{display:flex;align-items:center;gap:12px;flex-shrink:0}.res-state{font-size:11px;font-weight:750}.res-right svg{width:15px;height:15px;color:#78949b}.feed{padding:5px 20px 20px;min-height:260px}.event{display:flex;align-items:start;gap:12px;padding:13px 0;border-bottom:1px solid #263942}.event:last-child{border-bottom:0}.event-icon{height:28px;width:28px;border-radius:9px;background:#15392f;color:var(--green);display:grid;place-items:center;flex-shrink:0}.event-icon.warn{background:#423023;color:var(--amber)}.event-icon.info{background:#1b3245;color:var(--blue)}.event-icon svg{width:15px;height:15px}.event-main{min-width:0;flex:1}.event-title{font-size:12px;font-weight:750}.event-body{font-size:11px;color:#849da5;margin-top:3px}.event-time{font-size:10px;color:#73929b;white-space:nowrap}.compact-heat{display:flex;gap:2px;align-items:center;min-width:0}.compact-heat .hcell{height:15px;flex:1;border-radius:2px;min-width:2px;border:0;padding:0}.hcell.ok{background:#3e9b78}.hcell.fail{background:#e99969}.hcell.unknown{background:#395058}.hcell:hover{outline:1px solid #e1f7ec;outline-offset:1px}.history-rows{padding:0 20px 19px}.history-row{margin:14px 0}.history-name{display:flex;justify-content:space-between;gap:10px;font-size:11px;color:#b5d1d2;margin-bottom:7px}.history-name strong{font-weight:700}.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:10px;color:#9ab0b4}.legend span{display:flex;align-items:center;gap:5px}.square{height:8px;width:8px;border-radius:2px;display:inline-block}.timeline{display:flex;justify-content:space-between;color:#688991;font-size:10px;margin:8px 20px 15px}.toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:9px}.toolbar label{color:#7c9fa7;font-size:11px}.select{appearance:none;background:#172b32;border:1px solid #3b535d;border-radius:9px;color:#e4f2f1;padding:10px 31px 10px 12px;min-width:115px;background-image:url('data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="%2390b9b8" stroke-width="3"%3E%3Cpath d="m6 9 6 6 6-6"/%3E%3C/svg%3E');background-position:right 10px center;background-repeat:no-repeat}.tab{display:none}.tab.active{display:block}.metrics-strip{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.mini-value{font-size:23px;font-weight:800;margin-top:6px}.path-flow{padding:15px 20px 22px;display:grid;grid-template-columns:1fr auto 1fr auto 1fr auto 1fr;align-items:center;gap:7px}.path-node{padding:16px 7px;text-align:center;background:#192d34;border:1px solid #355158;border-radius:12px;min-height:106px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:7px}.path-node svg{width:24px;height:24px;color:var(--green)}.path-node strong{font-size:12px}.path-node small{font-size:10px;color:#91afb4}.flow-arrow{font-size:20px;color:#739b9c}.note{background:#142b31;border:1px solid #30535d;border-radius:12px;padding:14px 16px;color:#abc6c8;font-size:12px;line-height:1.65}.note.amber-note{background:#2a261e;border-color:#61503c;color:#e7c79f}.exception{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr) auto;gap:15px;align-items:center;padding:16px 20px;border-top:1px solid #2a3e46}.exception .muted{color:#809ba3;font-size:11px;margin-bottom:5px}.exception strong{font-size:13px}.exception code{font-size:11px;overflow-wrap:anywhere}.warn-pill{background:#3c2e24;border:1px solid #795640;color:#fac18f;border-radius:100px;padding:5px 9px;font-size:10px;font-weight:800;white-space:nowrap}.empty{padding:29px 20px;text-align:center;color:#84a8aa}.empty svg{width:28px;height:28px;margin:0 auto 8px}.empty strong{display:block;color:#d9eae8;margin-bottom:5px}.inspector-backdrop{position:fixed;inset:0;background:#0008;z-index:29;display:none}.inspector-backdrop.open{display:block}.inspector{position:fixed;right:0;top:0;bottom:0;z-index:30;width:min(420px,100%);background:#102028;border-left:1px solid #426168;box-shadow:-20px 0 70px #0008;transform:translateX(105%);transition:transform .24s;padding:30px;overflow:auto}.inspector.open{transform:translateX(0)}.inspector-close{float:right;border:1px solid #41606a;background:#19323c;color:#ddeced;border-radius:9px;width:33px;height:33px}.inspector h2{font-size:25px;letter-spacing:-.6px;margin:22px 0 5px}.inspect-field{padding:14px 0;border-bottom:1px solid #2c444b;display:flex;justify-content:space-between;gap:15px;font-size:12px}.inspect-field span{color:#88a9b0}.policy-row{display:flex;justify-content:space-between;gap:12px;padding:12px 0;border-bottom:1px solid #274049;font-size:12px}.policy-row strong{font-size:11px}.footer{color:#65848b;font-size:11px;margin-top:30px;display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap}.spacer{flex:1}.hidden{display:none!important}.alert-caption{background:#392b22;color:#ffe0b1;padding:9px 12px;border-radius:9px;font-size:11px}.tabs-mobile{display:none}.ext{color:var(--green);text-decoration:none}.ext:hover{text-decoration:underline}
@media(max-width:1150px){.main{padding:25px 23px 45px}.sidebar{width:210px}.main{width:calc(100% - 210px)}.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.hero h2{font-size:31px}.two-col{grid-template-columns:1fr}.hero{grid-template-columns:1.25fr .75fr}}
@media(max-width:760px){.app{display:block}.sidebar{width:auto;height:auto;position:relative;padding:15px 18px;border-right:0;border-bottom:1px solid #253f46}.logo{padding:0;margin:0}.sidebar .side-section,.sidebar .nav,.sidebar .side-bottom{display:none}.main{width:100%;padding:20px 15px 45px}.top{display:block;margin-bottom:16px}.page-title{font-size:26px}.top-tools{justify-content:flex-start;margin-top:15px}.hero{padding:22px;grid-template-columns:1fr;gap:9px;min-height:0}.hero h2{font-size:28px}.heartbeat{flex-direction:row;justify-content:flex-start;gap:15px;padding:12px 4px 0}.heart-ring{width:69px;height:69px;box-shadow:0 0 0 7px #43b18c0d}.heart-ring:after{inset:7px}.heart-ring svg{width:34px;height:34px}.heart-detail{margin:0}.heartbeat small{display:block}.ecg{width:95px}.stats{gap:8px}.stat{min-height:104px;padding:13px}.stat-val{font-size:24px}.path-flow{grid-template-columns:1fr;gap:5px}.flow-arrow{transform:rotate(90deg);text-align:center}.exception{grid-template-columns:1fr;gap:7px}.tabs-mobile{display:flex;gap:6px;overflow:auto;padding:0 0 14px}.m-tab{border:1px solid #344f56;background:#14242b;border-radius:9px;padding:9px 13px;color:#9bb6b9;white-space:nowrap}.m-tab.active{background:#1b4740;color:var(--green);border-color:#3d886b}.metrics-strip{grid-template-columns:1fr}.inspector{padding:24px}.event{gap:8px}}
@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation-duration:.01ms!important;transition-duration:.01ms!important;scroll-behavior:auto!important}}

/* Consistent event severity in both Recent Activity and full History.
   Keep the text legible: a narrow accent and a quiet tinted row, not solid fill. */
.event {
  --rg-event-accent: var(--blue);
  --rg-event-fill: #93c8f90a;
  --rg-event-border: #93c8f92d;
  --rg-event-icon-bg: #1b3245;
  margin: 6px 0;
  padding: 12px 11px;
  border: 1px solid var(--rg-event-border);
  border-left: 3px solid var(--rg-event-accent);
  border-radius: 10px;
  background: var(--rg-event-fill);
}
.event:last-child { border-bottom: 1px solid var(--rg-event-border); }
.event.event-recovery {
  --rg-event-accent: var(--green);
  --rg-event-fill: #63e8b60b;
  --rg-event-border: #63e8b631;
  --rg-event-icon-bg: #15392f;
}
.event.event-warning {
  --rg-event-accent: var(--amber);
  --rg-event-fill: #ffbd690b;
  --rg-event-border: #ffbd6933;
  --rg-event-icon-bg: #423023;
}
.event.event-critical {
  --rg-event-accent: var(--red);
  --rg-event-fill: #ff817e0c;
  --rg-event-border: #ff817e36;
  --rg-event-icon-bg: #45292b;
}
.event .event-icon {
  color: var(--rg-event-accent);
  background: var(--rg-event-icon-bg);
  font-weight: 800;
}
.event .event-title { line-height: 1.5; overflow-wrap: anywhere; }
.event .event-time { color: #9ab2bb; }
.event-legend { display: flex; flex-wrap: wrap; gap: 8px 14px; }
.event-legend span { display: inline-flex; align-items: center; gap: 6px; font-size: 10px; color: #a7bdc4; }
.event-legend i { width: 7px; height: 7px; border-radius: 50%; background: var(--rg-legend); }
@media(max-width:540px) {
  .event { gap: 9px; }
  .event-time { white-space: normal; text-align: right; }
}

/* Embedded dashboard runs inside the native Merlin ASP shell. */
body.rg-embedded { min-height:0; margin:0; }
body.rg-embedded .app { min-height:0; display:block; }
body.rg-embedded .sidebar { display:none!important; }
body.rg-embedded .main { width:100%; max-width:none; padding:16px 14px 34px; }
body.rg-embedded .tabs-mobile { display:flex; gap:6px; overflow:auto; padding:0 0 14px; }
body.rg-embedded .hero { grid-template-columns:1fr; padding:22px; }
body.rg-embedded .hero h2 { font-size:28px; }
body.rg-embedded .heartbeat { flex-direction:row; justify-content:flex-start; padding:10px 0 0; }
body.rg-embedded .heart-ring { width:72px; height:72px; }
body.rg-embedded .heart-ring svg { width:36px; height:36px; }
body.rg-embedded .heart-detail { margin:0; }
body.rg-embedded .heartbeat { width:100%; min-width:0; gap:15px; }
body.rg-embedded .heart-ring { flex-shrink:0; }
body.rg-embedded .heart-copy { flex:0 1 auto; min-width:0; }
body.rg-embedded .ecg { flex:1 1 0; width:auto; min-width:0; height:35px; }
/* Keep the trace responsive on standalone mobile views as well. */
@media(max-width:760px){
  .heartbeat { width:100%; min-width:0; }
  .heart-ring { flex-shrink:0; }
  .heart-copy { flex:0 1 auto; min-width:0; }
  .ecg { flex:1 1 0; width:auto; min-width:0; }
}
/* On extremely narrow screens, move the ECG below the status text rather
   than truncate the heart icon or obscure the completion label. */
@media(max-width:540px){
  .heartbeat { flex-wrap:wrap; }
  .ecg, body.rg-embedded .ecg { flex:1 1 100%; }
}
@media(max-width:860px){body.rg-embedded .stats{grid-template-columns:repeat(2,minmax(0,1fr))}}

/* The monitoring state drives ONE signal palette. A degraded result is
   amber from the heart through the return echo; red is reserved for a
   critical/hold signal. This avoids competing amber/red ECG layers. */
.heartbeat {
  --rg-signal: var(--green);
  --rg-signal-glow: #63e8b678;
  --rg-ring: #63e8b637;
  --rg-ring-soft: #63e8b612;
}
.heartbeat.signal-degraded {
  --rg-signal: var(--amber);
  --rg-signal-glow: #ffbd6980;
  --rg-ring: #ffbd6948;
  --rg-ring-soft: #ffbd691b;
}
.heartbeat.signal-hold {
  --rg-signal: var(--red);
  --rg-signal-glow: #ff817e80;
  --rg-ring: #ff817e48;
  --rg-ring-soft: #ff817e1b;
}
.heartbeat .heart-ring {
  border-color: var(--rg-ring);
  box-shadow: 0 0 0 4px var(--rg-ring-soft), 0 0 0 9px var(--rg-ring-soft);
  transition: border-color .25s ease, box-shadow .25s ease;
}
.heartbeat .heart-ring svg { color:var(--rg-signal); }
.heartbeat .heart-ring::after { border-color:var(--rg-ring); }
.heartbeat .heart-ring::before {
  content:"";
  position:absolute;
  inset:6px;
  border:2px solid transparent;
  border-top-color:var(--rg-signal);
  border-right-color:var(--rg-ring);
  border-radius:50%;
  opacity:.74;
  pointer-events:none;
  filter:drop-shadow(0 0 2px var(--rg-signal-glow));
}
/* Both pulses use the active status colour. The return echo gives the
   heart a slightly stronger, compact pulse without triggering another check. */
.heartbeat .heart-ring.pulse {
  animation:rg-ring-pulse 1.5s ease-out, rg-ring-return .95s ease-out 2.95s;
}
.heartbeat .heart-ring.pulse svg {
  animation:icon-pulse 1.5s ease-out, rg-icon-return .95s ease-out 2.95s;
}
@keyframes rg-ring-pulse {
  0% { box-shadow:0 0 0 3px var(--rg-ring),0 0 0 7px var(--rg-ring-soft),0 0 4px 0 var(--rg-signal-glow); }
  45% { box-shadow:0 0 0 8px var(--rg-ring),0 0 0 17px var(--rg-ring-soft),0 0 11px 2px var(--rg-signal-glow); }
  72% { box-shadow:0 0 0 12px var(--rg-ring-soft),0 0 0 19px transparent,0 0 7px 0 var(--rg-signal-glow); }
  100% { box-shadow:0 0 0 4px var(--rg-ring-soft),0 0 0 9px var(--rg-ring-soft),0 0 0 0 transparent; }
}
@keyframes rg-ring-return {
  0% { box-shadow:0 0 0 3px var(--rg-ring),0 0 0 7px var(--rg-ring-soft),0 0 4px 0 var(--rg-signal-glow); }
  42% { box-shadow:0 0 0 10px var(--rg-ring),0 0 0 20px var(--rg-ring-soft),0 0 13px 3px var(--rg-signal-glow); }
  72% { box-shadow:0 0 0 13px var(--rg-ring-soft),0 0 0 20px transparent,0 0 8px 0 var(--rg-signal-glow); }
  100% { box-shadow:0 0 0 4px var(--rg-ring-soft),0 0 0 9px var(--rg-ring-soft),0 0 0 0 transparent; }
}
@keyframes rg-icon-return {
  0%,100% { transform:scale(1); }
  22% { transform:scale(1.21); }
  48% { transform:scale(.96); }
}
/* Ambient activity remains decorative. Only a real completed monitoring cycle
   triggers the outgoing/returning QRS deformation in the SAME SVG trace. */
.heartbeat.motion-active .heart-ring::after { animation:rg-heart-dots 17s linear infinite; }
.heartbeat.motion-active .heart-ring::before { animation:rg-heart-arc 22s linear infinite reverse; }
.heartbeat.motion-active .ecg .ecg-trace { animation:rg-ecg-breathe 5.5s ease-in-out infinite; }
@keyframes rg-ecg-breathe { 0%,100% {opacity:.84} 50% {opacity:1} }
@keyframes rg-heart-dots { to { transform:rotate(360deg); } }
@keyframes rg-heart-arc { to { transform:rotate(360deg); } }
.ecg { overflow:hidden; flex-shrink:0; }
.heartbeat .ecg .ecg-trace {
  stroke:var(--rg-signal);
  stroke-width:2.25;
  stroke-linecap:round;
  stroke-linejoin:round;
  opacity:.95;
  transition:opacity .3s ease, stroke .25s ease;
  filter:drop-shadow(0 0 3px var(--rg-signal-glow));
}
.heartbeat.no-signal .ecg .ecg-trace { opacity:.28; }
/* Return echo is brighter/thicker, but ALWAYS the same hue as the baseline. */
.heartbeat .ecg .ecg-return {
  fill:none;
  stroke:var(--rg-signal);
  stroke-width:3.2;
  stroke-linecap:round;
  stroke-linejoin:round;
  pointer-events:none;
  filter:drop-shadow(0 0 5px var(--rg-signal-glow));
}
.heartbeat .ecg .ecg-turn {
  fill:var(--rg-signal);
  /* SVG's opacity attribute is driven by the JS turnaround flash. A CSS
     opacity:0 here would override the attribute and hide the flash. */
  pointer-events:none;
  filter:drop-shadow(0 0 4px var(--rg-signal-glow));
}
@media(prefers-reduced-motion:reduce) {
  .heartbeat .heart-ring::before,
  .heartbeat .heart-ring::after,
  .heartbeat .heart-ring.pulse,
  .heartbeat .heart-ring.pulse svg { animation:none!important; }
  .ecg .ecg-trace, .ecg .ecg-return, .ecg .ecg-turn { filter:none; }
  .heartbeat .ecg .ecg-trace,
  .heartbeat.running .heart-ring svg { animation:none!important; }
}

.history-row .history-live-count {font-size:10px;color:#98dabc;font-weight:650;white-space:nowrap}
.history-row .history-live-count.pending {color:var(--amber)}
@keyframes history-check-arrived {0%{box-shadow:0 0 0 0 #91efbb88}45%{box-shadow:0 0 0 3px #91efbb88}100%{box-shadow:0 0 0 0 #91efbb00}}
.compact-heat .hcell.history-new {animation:history-check-arrived 1.1s ease-out}
@media(prefers-reduced-motion:reduce){.compact-heat .hcell.history-new{animation:none}}

@media(prefers-reduced-motion:reduce) {
  .ecg .ecg-trace { transition:none; }
}


.manual-panel{border:1px solid #3b6570;background:linear-gradient(120deg,#172d34,#12232c);border-radius:14px;margin-bottom:20px;overflow:hidden;box-shadow:0 12px 30px #0002}
.manual-panel[hidden]{display:none!important}.manual-head{padding:17px 20px;border-bottom:1px solid #31515a;display:flex;justify-content:space-between;align-items:flex-start;gap:12px}.manual-head strong{font-size:15px;color:#f0f8f5}.manual-help{font-size:12px;color:#a0c2c0;margin-top:5px}.manual-content{padding:15px 20px}.manual-foot{border-top:1px solid #29434a;padding:11px 20px;font-size:11px;color:#8aaeb0}.manual-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:9px}.manual-item{border:1px solid #36555b;background:#142b32;border-radius:9px;padding:11px}.manual-item strong{display:block;font-size:12px}.manual-item small{display:block;color:#9fbdc1;margin-top:5px;overflow-wrap:anywhere}.manual-status{font-weight:800;font-size:20px;margin:0 0 10px}.manual-log{margin-top:12px;max-height:290px;overflow:auto;border:1px solid #31515b;border-radius:9px}.manual-log details{border-bottom:1px solid #29434b;padding:9px 12px;font-size:12px}.manual-log details:last-child{border-bottom:0}.manual-log summary{cursor:pointer;color:#c5e8dd;font-weight:700}.manual-check{padding:8px 0 7px 10px;border-bottom:1px solid #223841;font-size:11px;overflow-wrap:anywhere}.manual-check:last-child{border:0}.manual-check .pass{color:#70e2b1}.manual-check .fail{color:#f7a677}.manual-inline-busy{display:inline-block;width:12px;height:12px;border-radius:50%;border:2px solid #527e77;border-top-color:#74f2bc;animation:rgmanual-spin .85s linear infinite;vertical-align:middle;margin-right:7px}@keyframes rgmanual-spin{to{transform:rotate(360deg)}}

/* ResolvGuard settings and backup resolver controls */
.rg-config-note{margin:2px 0 0;line-height:1.65}.rg-fields{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:13px 17px}.rg-fields label,.rg-setting-row label{font-size:12px;font-weight:700;color:#b5ced2;display:flex;flex-direction:column;gap:6px}.rg-input{width:100%;font:inherit;color:#ecf7f3;background:#0d1d25;border:1px solid #385660;border-radius:9px;padding:10px;min-width:0}.rg-input:focus-visible{outline:2px solid var(--green);outline-offset:1px}.rg-input:disabled{opacity:.6}.rg-actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:16px}.rg-divider{border-top:1px solid var(--line);margin:20px 0}.rg-backup-row,.rg-setting-row{padding:14px 18px;border-bottom:1px solid #243c44;display:flex;align-items:center;justify-content:space-between;gap:15px}.rg-backup-row:last-child,.rg-setting-row:last-child{border-bottom:0}.rg-backup-info strong{font-size:13px;display:block}.rg-backup-info small{color:var(--sub);display:block;overflow-wrap:anywhere;margin-top:5px}.rg-setting-row .rg-control{display:flex;align-items:center;gap:9px}.rg-setting-row .rg-input{width:110px}.rg-configuration-status{position:sticky;bottom:10px;z-index:50;padding:13px 16px;margin-top:14px;border:1px solid #3c7260;border-radius:10px;background:#17352f;color:#c4ffe5;box-shadow:0 10px 22px #0006}.rg-configuration-status.error{border-color:#8d5a53;background:#3c2426;color:#ffd1c6}.rg-configuration-status[hidden]{display:none!important}@media(max-width:820px){.rg-fields{grid-template-columns:1fr}.rg-backup-row,.rg-setting-row{align-items:flex-start;flex-direction:column}.rg-setting-row .rg-control{width:100%}}
</style>
<script>document.body.classList.add('rg-embedded');</script>
<div class="app">
<aside class="sidebar">
  <div class="logo"><div class="logo-mark"><svg viewBox="0 0 24 24" fill="none" stroke="#eafff4" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 4 5v6c0 5.2 3.2 8.9 8 11 4.8-2.1 8-5.8 8-11V5l-8-3Z"/><path d="M7 13h3l1.5-3 2 5 1.5-2H17"/></svg></div><div><div class="brand">ResolvGuard</div><div class="brand-sub">DNS observability</div></div></div>
  <div class="side-section">Workspace</div>
  <button class="nav active" data-tab="overview" aria-current="page"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="3" width="8" height="5" rx="1.5"/><rect x="13" y="10" width="8" height="11" rx="1.5"/><rect x="3" y="13" width="8" height="8" rx="1.5"/></svg> Overview</button>
  <button class="nav" data-tab="history"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18M6 17l5-6 4 3 6-8"/></svg> Health history</button>
  <button class="nav" data-tab="paths"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="5" cy="12" r="3"/><circle cx="19" cy="5" r="3"/><circle cx="19" cy="19" r="3"/><path d="M8 12h5m0 0 3-5m-3 5 3 5"/></svg> DNS paths & exceptions</button>
  <button class="nav" data-tab="backups"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="6" cy="12" r="3"/><circle cx="18" cy="6" r="3"/><circle cx="18" cy="18" r="3"/><path d="M9 12h6m-1-4 2-2m-2 10 2 2"/></svg> Backup &amp; Alternate Resolvers</button>
  <button class="nav" data-tab="settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M12 2v3m0 14v3M4 4l2.2 2.2M17.8 17.8 20 20M2 12h3m14 0h3M4 20l2.2-2.2M17.8 6.2 20 4"/></svg> Settings</button>
  <div class="side-bottom"><div class="small-pill"><span class="dot"></span> DNS monitoring</div><div class="small-note">Scheduled monitoring snapshots<br>Optional read-only live checks<br>Primary WAN DNS stays in ASUS settings</div></div>
</aside>
<main class="main">
  <div class="tabs-mobile"><button class="m-tab active" data-tab="overview">Overview</button><button class="m-tab" data-tab="history">History</button><button class="m-tab" data-tab="paths">DNS Paths</button><button class="m-tab" data-tab="backups">Backups</button><button class="m-tab" data-tab="settings">Settings</button></div>
  <header class="top"><div><div class="eyebrow">Intelligent DNS monitoring</div><h1 class="page-title" id="pageTitle">Dashboard overview</h1><div class="desc" id="pageDesc">Your DNS reliability, clearly visible.</div></div><div class="top-tools"><span class="tag demo" id="feedStatus">CONNECTING...</span><button class="btn primary" id="runHealthCheck"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v18M3 12h18"/></svg> Run Health Check</button></div></header>
  <section class="manual-panel" id="manualPanel" hidden aria-live="polite">
    <div class="manual-head"><div><strong id="manualTitle">Manual health check</strong><div class="manual-help" id="manualSummary">A separate, read-only authenticated DoT policy evaluation.</div></div><button type="button" class="inspector-close" id="manualClose" aria-label="Close manual health-check results">×</button></div>
    <div class="manual-content" id="manualResults"></div>
    <div class="manual-foot">Manual observations do not change the active WAN pool, scheduled heartbeat, or reliability history.</div>
  </section>

  <section id="overview" class="tab active">
    <div class="hero" id="hero"><div><div class="hero-kicker"><span class="dot" id="heroDot"></span><span id="heroKicker">Monitoring status unknown</span></div><h2 id="heroHeading">Connecting to ResolvGuard…</h2><p id="heroText">Waiting for a completed scheduled DNS health check.</p><div class="hero-meta"><span id="poolPill">Active pool: unknown</span><span id="modePill">Mode unknown</span></div></div>
      <div class="heartbeat no-signal" id="heartbeat"><div class="heart-ring" id="heartRing"><svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M32 54C19 45 9 36 9 23a12 12 0 0 1 22-6 12 12 0 0 1 22 6c0 13-10 22-21 31Z"/><path d="M16 30h10l5-11 7 22 5-11h5"/></svg></div><div class="heart-copy"><div class="heart-detail" id="heartLabel">Awaiting checks</div><small id="heartSub">Waiting for scheduled check</small></div><svg class="ecg" id="ecgWave" viewBox="0 0 185 35" aria-hidden="true" focusable="false"><path id="ecgTrace" class="ecg-trace" d="M0 17.5 H185" /><path id="ecgReturn" class="ecg-return" d="" /><circle id="ecgTurn" class="ecg-turn" cx="183" cy="17.5" r="2.4" opacity="0" /></svg></div>
    </div>
    <div class="section-head"><h3>Network health at a glance</h3><div class="hint">Scheduled monitoring · Manual checks are independent</div></div>
    <div class="stats">
      <div class="stat"><div class="stat-label">Preferred resolvers</div><div class="stat-val green" id="statResolvers">—</div><div class="stat-sub" id="statResolversSub">Reachable and policy-compliant</div></div>
      <div class="stat"><div class="stat-label">DNS probe results</div><div class="stat-val" id="statPolicies">—</div><div class="stat-sub">Passed / total · latest cycle</div></div>
      <div class="stat"><div class="stat-label">Active production pool</div><div class="stat-val" id="statPool" style="font-size:23px">unknown</div><div class="stat-sub" id="statPoolSub">WAN DNS configuration</div></div>
      <div class="stat"><div class="stat-label">Next scheduled cycle</div><div class="stat-val" id="statCountdown">—</div><div class="stat-sub" id="statSeq">No completed check yet</div></div>
    </div>
    <div class="section-head"><h3>Live resolver view</h3><button class="text-link" data-tab="history">Explore full history →</button></div>
    <div class="two-col">
      <div class="card"><div class="card-head"><div><div class="card-title">Preferred DNS resolvers</div><div class="card-sub">Tap a resolver for authentication and policy details</div></div><div class="small-pill" id="preferredCount">— healthy</div></div><div id="resolverList"></div><div class="card-pad" style="padding-top:10px"><div class="note">These are <strong>direct authenticated DoT probes</strong>. Production LAN DNS still uses DNSMasq → Stubby by default.</div></div></div>
      <div class="card"><div class="card-head"><div><div class="card-title">Recent activity</div><div class="card-sub">Actual completed failover and recovery events</div></div><button class="text-link" data-tab="history">All events →</button></div><div class="feed" id="eventFeed"></div></div>
    </div>
    <div class="section-head"><h3>Quick reliability history</h3><span class="hint">Last 24 hours · 30-minute segments · live check counts</span></div>
    <div class="card"><div class="card-head"><div><div class="card-title">Health by resolver</div><div class="card-sub">The rightmost segment fills as completed checks are recorded; hover or click for exact counts</div></div><div class="legend"><span><i class="square" style="background:#3e9b78"></i>Passed</span><span><i class="square" style="background:#e99969"></i>Failed</span><span><i class="square" style="background:#395058"></i>No observation</span></div></div><div class="history-rows" id="overviewHeat"></div><div class="timeline"><span>24 hours ago</span><span>12 hours ago</span><span>Now</span></div></div>
  </section>

  <section id="history" class="tab">
    <div class="section-head" style="margin-top:0"><h3>Reliability across time</h3><div class="toolbar"><label for="period">Time period</label><select id="period" class="select"><option value="24">Last 24 hours</option><option value="7">Last 7 days</option></select></div></div>
    <div class="metrics-strip"><div class="stat"><div class="stat-label">Recent observations</div><div class="mini-value" id="histObservations">192</div><div class="stat-sub">Recorded policy observations</div></div><div class="stat"><div class="stat-label">Preferred endpoints</div><div class="mini-value" id="histPreferred">—</div><div class="stat-sub">Independently checked</div></div><div class="stat"><div class="stat-label">Live data source</div><div class="mini-value amber" style="font-size:18px">Live feed</div><div class="stat-sub">Volatile history; resets on reboot</div></div></div>
    <div class="section-head"><h3>Resolver health timeline</h3><div class="legend"><span><i class="square" style="background:#3e9b78"></i>Passed</span><span><i class="square" style="background:#e99969"></i>Failed</span><span><i class="square" style="background:#395058"></i>Unknown</span></div></div>
    <div class="card"><div class="card-head"><div><div class="card-title">Historical policy outcomes</div><div class="card-sub">Click any interval to inspect the observation, or select a resolver card</div></div><span class="tag">Live timeline</span></div><div class="history-rows" id="fullHeat"></div><div class="timeline" id="histAxis"><span>24 hours ago</span><span>12 hours ago</span><span>Now</span></div></div>
    <div class="section-head"><h3>Selected observation</h3></div>
    <div class="card card-pad" id="selectedInterval"><div class="desc">Choose any colored interval in the timeline to inspect its sample result.</div></div>
    <div class="section-head"><h3>Failover & recovery events</h3><div class="event-legend" aria-label="Event colours"><span><i style="--rg-legend:var(--green)"></i>Restored</span><span><i style="--rg-legend:var(--amber)"></i>Filtered / warning</span><span><i style="--rg-legend:var(--red)"></i>Backup / critical</span><span><i style="--rg-legend:var(--blue)"></i>Info</span></div></div>
    <div class="card"><div id="historyEvents" class="feed"></div></div>
  </section>

  <section id="paths" class="tab">
    <div class="section-head" style="margin-top:0"><h3>Normal forwarding path</h3><span class="small-pill">Configuration-derived</span></div>
    <div class="card"><div class="card-head"><div><div class="card-title">DNSMasq → Stubby → Strict DoT</div><div class="card-sub">Default DNS forwarding for queries received by the router</div></div></div><div class="path-flow">
      <div class="path-node"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="4" width="20" height="14" rx="2"/><path d="M8 22h8m-4-4v4"/></svg><strong>LAN query</strong><small>To router DNS</small></div><div class="flow-arrow">→</div>
      <div class="path-node"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="2" width="18" height="8" rx="2"/><rect x="3" y="14" width="18" height="8" rx="2"/><path d="M7 6h.01M7 18h.01"/></svg><strong>DNSMasq</strong><small>Local DNS</small></div><div class="flow-arrow">→</div>
      <div class="path-node"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2 4 5v6c0 5 3.5 9 8 11 4.5-2 8-6 8-11V5l-8-3Z"/><path d="M9 12l2 2 4-4"/></svg><strong>Stubby</strong><small>Authenticated TLS</small></div><div class="flow-arrow">→</div>
      <div class="path-node"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c-4 5-4 13 0 18M12 3c4 5 4 13 0 18"/></svg><strong>DoT upstream</strong><small>TCP port 853</small></div>
    </div><div class="card-pad" style="padding-top:0"><div class="note">ResolvGuard separately queries resolvers through direct authenticated DoT for independent health assessments. Those intentional probes do not use production Stubby.</div></div></div>
    <div class="section-head"><h3>Configured Stubby-bypass exceptions</h3><span class="warn-pill">Bypass warning from Quick Setup</span></div>
    <div class="card"><div class="card-head"><div><div class="card-title">Domain-scoped DNSMasq upstream rules</div><div class="card-sub">From <code>/tmp/resolv.dnsmasq</code> via <code>server=/domain/IP</code></div></div><div id="exceptionList"></div><div class="card-pad" style="padding-top:9px"><p class="desc">Read-only results from the same DNSMasq upstream file used by the installer warning. Not a complete audit of LAN device traffic.</p></div></div>
  </section>
  <section id="backups" class="tab">
    <div class="section-head" style="margin-top:0"><h3>Backup &amp; Alternate Resolvers</h3><span class="hint">ResolvGuard-managed encrypted DNS backups</span></div>
    <div class="note rg-config-note">Primary/preferred DNS is configured through <strong>ASUS WAN → DNS Privacy</strong>, not here. These backup endpoints are used only according to ResolvGuard's verified failover policy. Editing backup configuration may require renewed policy approval.</div>
    <div class="card" style="margin-top:16px">
      <div class="card-head"><div><div class="card-title">Configured backup resolvers</div><div class="card-sub">Configured endpoints are not assumed healthy until independently checked</div></div><div style="display:flex;gap:8px;flex-wrap:wrap"><span class="small-pill" id="backupPoolState">Pool: unknown</span><span class="small-pill" id="backupCount">—</span></div></div>
      <div id="backupRows"><div class="empty">Loading configuration…</div></div>
      <div class="card-pad" id="backupGroups" style="border-top:1px solid var(--line)"></div>
    </div>
    <div class="card" style="margin-top:18px">
      <div class="card-head"><div><div class="card-title">Add or edit a backup resolver</div><div class="card-sub">Validated IPv4/IPv6 address, TLS hostname and port; existing IDs cannot be renamed</div></div><button type="button" class="btn" id="backupReset">Clear</button></div>
      <div class="card-pad">
        <div class="rg-fields">
          <label>Resolver ID <input class="rg-input" id="backupId" maxlength="32" placeholder="backup1" autocomplete="off"></label>
          <label>DNS IP address <input class="rg-input" id="backupIp" maxlength="48" placeholder="1.1.1.2" autocomplete="off"></label>
          <label>Verified TLS hostname <input class="rg-input" id="backupTls" maxlength="120" placeholder="security.cloudflare-dns.com" autocomplete="off"></label>
          <label>TLS port <input class="rg-input" id="backupPort" type="number" min="1" max="65535" value="853"></label>
        </div>
        <div class="rg-actions"><button type="button" class="btn primary" id="backupSave" disabled>Save resolver</button><span class="hint" id="backupMode">Add new resolver</span></div>
        <div class="rg-divider"></div>
        <div class="card-title">Add a preset pair</div><p class="desc">Presets use the same checks and all-or-nothing configuration transaction as SSH.</p>
        <div class="rg-actions"><button type="button" class="btn rg-preset" data-preset="GO" disabled>Google</button><button type="button" class="btn rg-preset" data-preset="CS" disabled>Cloudflare Security</button><button type="button" class="btn rg-preset" data-preset="QS" disabled>Quad9 Security</button></div>
      </div>
    </div>
  </section>
  <section id="settings" class="tab">
    <div class="section-head" style="margin-top:0"><h3>ResolvGuard settings</h3><span class="hint">Configuration saved through authenticated ASUS service actions</span></div>
    <div class="note rg-config-note">These settings govern ResolvGuard's monitoring behavior. Preferred WAN resolvers, DNS Privacy settings, and automatic failover authorization are <strong>not edited here</strong>. Those retain their existing ASUS and SSH approval workflows.</div>
    <div class="card" style="margin-top:16px">
      <div class="card-head"><div><div class="card-title">Monitoring &amp; health-check parameters</div><div class="card-sub" id="settingsSummary">Loading saved configuration…</div></div></div>
      <div id="settingsRows"></div>
    </div>
  </section>
  <div class="rg-configuration-status" id="configFeedback" role="status" aria-live="polite" hidden></div>
  <footer class="footer"><span>ResolvGuard dashboard · Authenticated backup/settings changes · No WAN DNS writes</span><span>Heartbeat follows completed scheduled cycles · History stored in /tmp</span></footer>
</main>
</div>
<div id="inspectBackdrop" class="inspector-backdrop" tabindex="-1"></div>
<aside class="inspector" id="inspector" aria-label="Resolver details" aria-hidden="true" role="dialog" aria-modal="true"><button id="inspectorClose" class="inspector-close" aria-label="Close">×</button><div class="eyebrow">Resolver inspector</div><div id="inspectContent"></div></aside>
<script>
/* ResolvGuard monitoring and authenticated configuration UI. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const fmtTime = v => {const d=Date.parse(v||'');return Number.isFinite(d)?new Date(d).toLocaleString():'No completed check';};
  // UTC is retained for arithmetic; local wall-clock times come from the router.
  // Display the router's clock without its offset; never use the viewer's time zone.
  function routerTimeLabel(stamp,short=false){
    const t=String(stamp||'');
    if(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}$/.test(t))
      return short?t.slice(11,19):t.slice(0,10)+' '+t.slice(11,19);
    return '';
  }
  function eventTimeLabel(event,short=false){
    return routerTimeLabel(event?.routerAt,short)||String(event?.at||'Unknown').replace('T',' ').replace(/Z$/,' UTC');
  }
  const since = v => {const d=Date.parse(v||'');if(!Number.isFinite(d))return 'No completed check';const sec=Math.max(0,Math.floor((Date.now()-d)/1000));return sec<60?sec+' seconds ago':Math.floor(sec/60)+' min ago';};
  const state={tab:'overview',period:'24',snapshot:null,history:[],lastEnd:'',lastFetch:0,polling:false,feedConnected:false,historyPending:'',historyBaseline:'',historyAttempts:0,historyAdvanced:false,manualBusy:false,manualPolling:null,manualPreviousId:'',manualRequestedAt:0,manualRunId:'',config:null,configBusy:false,configFresh:false,configLoading:false,editingBackupId:''};
  const hasRealChecks = d => (d?.resolvers||[]).some(r => r.policyPass+r.policyFail>0);
  function isStale(d){if(!d?.lastEnd)return true;const ms=Date.parse(d.lastEnd);return !Number.isFinite(ms)||Date.now()-ms>Math.max(150000,(d.scheduleMinutes||1)*150000);}
  function pref(d){return (d?.resolvers||[]).filter(r=>/^wan[0-9]+$/.test(r.id));}
  function health(d){
    if(!d||isStale(d)||!hasRealChecks(d))return 'unknown';
    if(d.pendingTransaction||d.recoveryHold)return 'hold';
    const p=pref(d);
    // Preferred-membership health is distinct from the currently active pool.
    if(!p.length||p.some(r=>r.state==='unknown'))return 'unknown';
    return p.some(r=>r.state==='fail')?'degraded':'healthy';
  }
  function topState(d){
    if(!d)return {title:'Connecting to ResolvGuard…',detail:'Waiting for the first status snapshot.',status:'unknown'};
    if(d.pendingTransaction||d.recoveryHold)return {title:'DNS recovery requires attention.',detail:'A pending transaction or recovery hold exists. Check the SSH status command before making changes.',status:'hold'};
    if(isStale(d))return {title:'Monitoring data is stale.',detail:'No recent completed health evaluation is available. This is not a passing result.',status:'unknown'};
    if(!hasRealChecks(d))return {title:'Waiting for health results.',detail:'The latest completed cycle had no DNS policy observations.',status:'unknown'};
    const h=health(d),p=pref(d),n=p.filter(r=>r.state==='ok').length;
    if(d.pool!=='preferred')return {title:'Failover pool active: '+d.pool,detail:`${n} of ${p.length} preferred resolvers passed the latest observed policy checks. A managed alternate pool is active; see the resolver and event details below.`,status:'degraded'};
    if(h==='healthy')return {title:'All preferred DNS resolvers are healthy.',detail:`All ${p.length} preferred resolvers passed the latest completed scheduled cycle.`,status:'healthy'};
    if(h==='degraded')return {title:'Preferred DNS health is degraded.',detail:`${n} of ${p.length} preferred resolvers passed. Refer to the detailed checks and event history.`,status:'degraded'};
    return {title:'DNS health is not fully verified.',detail:'Some enrolled resolvers were not observed in the last completed cycle.',status:'unknown'};
  }
  // One sampled ECG waveform, with a short colour overlay ON the same path
  // during its returning echo (not a second QRS spike). A completed scheduled
  // cycle starts the entire out-and-back *replay*: this does not claim that a
  // live DNS request is currently in flight or imply extra checks.
  const waveform=(() => {
    const path=$('ecgTrace'), echo=$('ecgReturn'), turn=$('ecgTurn'), svg=$('ecgWave');
    const reduced=window.matchMedia('(prefers-reduced-motion: reduce)');
    let width=185; // SVG user units follow its measured CSS width.
    const midpoint=17.5, outboundMs=1450, returnMs=1550;
    const duration=outboundMs+returnMs;
    let running=false, displayed=true, frame=0, beatAt=-Infinity, frozenAt=0;
    const gaussian=(x,sigma)=>Math.exp(-0.5*(x/sigma)*(x/sigma));
    function trace(t){
      const sec=t/1000;
      const elapsed=t-beatAt;
      const beating=Number.isFinite(elapsed)&&elapsed>=0&&elapsed<duration;
      const returning=beating&&elapsed>=outboundMs;
      // Travel slightly beyond both ends to let the single waveform enter
      // and leave naturally; reverse direction at the far edge.
      const span=width+56;
      const center=beating
        ? returning ? width+28-span*((elapsed-outboundMs)/returnMs)
                    : -28+span*(elapsed/outboundMs)
        : 0;
      const points=[],echoPoints=[];
      const samples=Math.max(80,Math.min(360,Math.ceil(width/1.5)));
      for(let i=0;i<=samples;i++){
        const x=width*i/samples;
        const idle=1.45*Math.sin(x*.115-sec*1.25)
          +0.56*Math.sin(x*.26+sec*.67);
        let beat=0,suppression=0;
        if(beating){
          // Mirror the QRS sequence when the response travels back.
          const dx=returning?center-x:x-center;
          suppression=.98*gaussian(dx,24);
          beat=-1.8*gaussian(dx+24,6.3)
            +3.2*gaussian(dx+8.0,3.5)
            -14.5*gaussian(dx,2.05)
            +12.0*gaussian(dx-6.5,2.8)
            -2.6*gaussian(dx-23,7.8);
        }
        const y=Math.max(1.5,Math.min(33.5,midpoint+idle*(1-suppression)+beat));
        const point=x.toFixed(2)+' '+y.toFixed(2);
        points.push((i===0?'M':'L')+point);
        // The echo trace follows the exact same geometry. Only a narrow
        // section is coloured aqua/red; the rest of the ECG stays legible.
        if(returning&&Math.abs(x-center)<=27)
          echoPoints.push((echoPoints.length?'L':'M')+point);
      }
      path.setAttribute('d',points.join(' '));
      echo.setAttribute('d',returning?echoPoints.join(' '):'');
      const bounce=returning?Math.max(0,1-(elapsed-outboundMs)/260):0;
      turn.setAttribute('opacity',bounce.toFixed(2));
    }
    function shouldAnimate(){
      return running&&displayed&&!reduced.matches&&!document.hidden;
    }
    function tick(now){
      frame=0;
      frozenAt=now;
      trace(now);
      if(shouldAnimate())frame=requestAnimationFrame(tick);
    }
    function update(){
      if(frame){cancelAnimationFrame(frame);frame=0;}
      if(!shouldAnimate()){
        // Stale, hidden and reduced-motion views never invent a pulse.
        beatAt=-Infinity;
        trace(reduced.matches?0:frozenAt);
      }else{
        frame=requestAnimationFrame(tick);
      }
    }
    function resize(){
      const measured=Math.round(svg.getBoundingClientRect().width);
      if(!measured||measured===width)return;
      width=measured;
      svg.setAttribute('viewBox',`0 0 ${width} 35`);
      turn.setAttribute('cx',String(Math.max(0,width-2)));
      trace(frozenAt);
    }
    document.addEventListener('visibilitychange',update);
    if(reduced.addEventListener)reduced.addEventListener('change',update);
    else if(reduced.addListener)reduced.addListener(update);
    if(window.ResizeObserver){
      const watcher=new ResizeObserver(resize);
      watcher.observe(svg);
    }else window.addEventListener('resize',resize);
    resize();
    trace(0);
    return {
      setActive(value){const next=!!value;if(next!==running){running=next;update();}},
      setVisible(value){const next=!!value;if(next!==displayed){displayed=next;update();}},
      active(){return shouldAnimate();},
      beat(){if(shouldAnimate()){
        beatAt=performance.now();
        // Both legs depict the LAST completed cycle, never an extra probe.
        if(!frame)frame=requestAnimationFrame(tick);
      }}
    };
  })();
  function syncWaveSignal(d, feedConnected=true){
    const live=feedConnected && !!d?.lastEnd && !isStale(d) && hasRealChecks(d);
    const node=$('heartbeat');
    node.classList.toggle('no-signal',!live);
    const summary=live?topState(d).status:'unknown';
    node.classList.toggle('signal-degraded',summary==='degraded');
    node.classList.toggle('signal-hold',summary==='hold');
    waveform.setActive(live);
    node.classList.toggle('motion-active',waveform.active());
    if(!live)$('heartRing').classList.remove('pulse');
  }
  document.addEventListener('visibilitychange',()=>syncWaveSignal(state.snapshot,state.feedConnected));
  function pulseCompletedCheck(){
    // A newly completed observed cycle is the only trigger (never UI motion).
    if(!state.feedConnected||isStale(state.snapshot)||!hasRealChecks(state.snapshot))return;
    const ring=$('heartRing');
    ring.classList.remove('pulse');
    void ring.getBoundingClientRect().width;
    ring.classList.add('pulse');
    waveform.beat();
  }
  const glyph={healthy:'✓',degraded:'!',unknown:'?',hold:'!'};
  // Classify actual shell-emitted events by action and destination pool.
  // filtered1/filtered2 are preferred-resolver subsets, not independent backups.
  // Independent backup pools are backupN/wanpoolN. Share one classifier across
  // the Overview activity feed and the full History event list.
  function eventKind(message){
    const m=String(message||'').trim();
    if (/^DNS (?:RESOLVER RESTORED|FILTERED RECOVERY):/i.test(m) ||
        /^DNS FAILBACK:.*->\s*preferred\b/i.test(m)) return 'recovery';
    if (/^(?:DNS RECOVERED:|FAST CONFIRM FAILED:)/i.test(m)) return 'info';

    // Only colour independent-backup transitions and explicitly identified
    // backup switching/recovery failures red. A filtered-pool failover is amber.
    const isPoolSwitch=/^DNS (?:FAILOVER|POOL CHANGE|SWITCH FAILED|RECOVERY FAILED|ROLLBACK FAILED|RECOVERY ATTENTION):/i.test(m);
    const targetIsIndependentBackup=/->\s*(?:backup[0-9]+|wanpool[0-9]+)\b/i.test(m);
    const failedIndependentBackup=/^DNS RECOVERY FAILED:\s*(?:backup[0-9]+|wanpool[0-9]+)\b/i.test(m);
    if (isPoolSwitch && (targetIsIndependentBackup || failedIndependentBackup)) return 'critical';

    if (/^DNS (?:RESOLVER EXCLUDED|FILTERED MEMBERSHIP|FAILOVER|POOL CHANGE|SWITCH FAILED|RECOVERY FAILED|ROLLBACK FAILED|RECOVERY ATTENTION|RECOVERY):/i.test(m)) return 'warning';
    return 'info';
  }
  function renderEvent(e, recent=false){
    const kind=eventKind(e?.message);
    const symbol=kind==='recovery'?'✓':kind==='info'?'i':'!';
    const body=recent?'<div class="event-body">Recorded by ResolvGuard\'s completed scheduled check</div>':'';
    return `<div class="event event-${kind}"><div class="event-icon" aria-hidden="true">${symbol}</div><div class="event-main"><div class="event-title">${esc(e?.message)}</div>${body}</div><span class="event-time">${esc(eventTimeLabel(e,recent))}</span></div>`;
  }
  function renderOverview(){
    const d=state.snapshot,s=topState(d),r=pref(d),n=r.filter(x=>x.state==='ok').length;
    syncWaveSignal(d,state.feedConnected);
    $('heroHeading').textContent=s.title; $('heroText').textContent=s.detail;
    $('heroKicker').textContent=s.status==='healthy'?'Monitoring healthy':s.status==='degraded'?'DNS degraded':'Verification pending';
    $('heroDot').style.background=s.status==='healthy'?'var(--green)':s.status==='degraded'?'var(--amber)':'var(--muted)';
    $('hero').style.borderColor=s.status==='healthy'?'#29564b':s.status==='degraded'?'#86633b':'#395058';
    $('poolPill').textContent='Active pool: '+(d?.pool||'unknown');
    $('modePill').textContent=({'monitoring':'Monitoring Only','automatic':'Auto Failover configured','inactive':'Monitoring inactive','hold':'Policy safety hold'})[d?.mode]||'Unknown mode';
    $('heartLabel').textContent=s.status==='healthy'?'Check complete · Healthy':s.status==='degraded'?'Check complete · Degraded':'Awaiting reliable check';
    $('heartSub').textContent=d?.lastEnd?'Last completed '+(routerTimeLabel(d.lastEndRouter)||String(d.lastEnd).replace('T',' ').replace(/Z$/,' UTC')):'No completed cycle recorded';
    $('statResolvers').textContent=d&&r.length?`${n} / ${r.length}`:'—';
    $('statResolversSub').textContent='Preferred members passing observed policy';
    const pol=r.reduce((z,x)=>z+x.policyPass,0),fail=r.reduce((z,x)=>z+x.policyFail,0);
    $('statPolicies').textContent=d&&pol+fail?`${pol} / ${pol+fail}`:'—';
    $('statPool').textContent=d?.pool||'unknown';
    $('statPoolSub').textContent='Read-only managed pool state';
    $('statSeq').textContent=d?.lastEnd?'Completed '+(routerTimeLabel(d.lastEndRouter)||String(d.lastEnd).replace('T',' ').replace(/Z$/,' UTC')):'No completed check yet';
    $('preferredCount').textContent=r.length?`${n}/${r.length} passing`:'Unenrolled / unknown';
    $('resolverList').innerHTML=r.length?r.map(x=>`<button class="resolve-row" data-resolver="${esc(x.id)}"><div class="res-left"><span class="status-glyph ${x.state==='fail'?'bad':''}">${x.state==='ok'?'✓':x.state==='fail'?'!':'?'}</span><div><div class="res-name">${esc(x.tls||x.id)}</div><div class="res-ip">${esc(x.id)} · ${esc(x.ip)}:${esc(x.port)}</div></div></div><div class="res-right"><span class="res-state ${x.state==='ok'?'green':x.state==='fail'?'red':'amber'}">${x.state==='ok'?'PASS':x.state==='fail'?'FAIL':'NOT OBSERVED'}</span><span>›</span></div></button>`).join(''):'<div class="empty">No preferred resolver roster available. Enroll preferred WAN DNS before monitoring.</div>';
    const ev=(d?.events||[]).slice(-5).reverse();
    $('eventFeed').innerHTML=ev.length?ev.map(e=>renderEvent(e,true)).join(''):'<div class="empty">No switching or recovery events recorded since this router boot.</div>';
    renderHeat('overviewHeat','24');
  }
  function renderHeat(id,period){
    const d=state.snapshot,r=pref(d),minutes=period==='24'?30:60,slots=period==='24'?48:168,now=Date.now();
    $(id).innerHTML=r.length?r.map(res=>{
      const bins=Array.from({length:slots},()=>({total:0,fail:0,unknown:0,at:''}));
      for(const b of state.history){if(b.id!==res.id)continue;
        const ts=Date.parse(b.at);if(!Number.isFinite(ts))continue;
        const age=Math.floor((now-ts)/(minutes*60000)),j=slots-1-age;
        if(j<0||j>=slots)continue;
        bins[j].total+=Number(b.samples||0);bins[j].fail+=Number(b.failures||0);bins[j].unknown+=Number(b.unknowns||0);bins[j].at=b.at;
      }
      const passed=bins.reduce((a,b)=>a+Math.max(0,b.total-b.fail-b.unknown),0),total=bins.reduce((a,b)=>a+b.total,0);
      const current=bins[slots-1],currentCount=current.total;
      const currentMessage=currentCount?`${currentCount} recorded check${currentCount===1?'':'s'} in current ${minutes}-minute segment`:`No checks recorded in current ${minutes}-minute segment`;
      const pending=!!state.historyPending;
      const caption=(total?Math.round(100*passed/total)+'% observed passes':'No observations')+' · '+currentMessage;
      return `<div class="history-row"><div class="history-name"><strong>${esc(res.tls)} <span style="color:#7e9ca5;font-weight:400">${esc(res.id)}</span></strong><span class="history-live-count ${pending?'pending':''}" data-history-count="${esc(res.id)}" title="${esc(caption)}">${currentCount} checks / ${minutes} min${pending?' · syncing…':''}</span></div><div class="compact-heat">${bins.map((b,j)=>{
        const cls=b.total?(b.fail?'fail':b.unknown?'unknown':'ok'):'unknown';
        const currentCell=j===slots-1;
        const liveClass=currentCell?' is-current'+(state.historyAdvanced?' history-new':''):'';
        const detail=b.total?`${b.total} observed check(s), ${b.fail} failures, ${b.unknown} unknown results`:'No sample in interval';
        return `<button class="hcell ${cls}${liveClass}" data-bin="${j}" data-period="${period}" data-resolver="${esc(res.id)}" title="${esc(detail)}" aria-label="${esc(res.id)}, ${esc(detail)}"></button>`;
      }).join('')}</div></div>`;
    }).join(''):'<div class="empty">No preferred resolver inventory yet.</div>';
  }
  // Used only to decide whether a new completed cycle reached history.htm;
  // the backend writes status.htm before history.htm, so the two can briefly differ.
  function historySignature(rows){return rows.slice(-16).map(b=>[b.at,b.id,b.samples,b.failures,b.unknowns].join('|')).join('~');}
  function renderHistory(){
    const d=state.snapshot;
    $('histObservations').textContent=String(state.history.reduce((a,b)=>a+Number(b.samples||0),0));
    $('histPreferred').textContent=String(pref(d).length||'—');
    $('histAxis').innerHTML=state.period==='24'?'<span>24 hours ago</span><span>12 hours ago</span><span>Now</span>':'<span>7 days ago</span><span>3.5 days ago</span><span>Now</span>';
    renderHeat('fullHeat',state.period);
    const ev=(d?.events||[]).slice().reverse();
    $('historyEvents').innerHTML=ev.length?ev.map(e=>renderEvent(e)).join(''):'<div class="empty">No logged recovery/failover events since the current boot.</div>';
  }
  function selectBin(id,period,index){
    const minutes=period==='24'?30:60,slots=period==='24'?48:168,start=Date.now()-(slots-index)*minutes*60000,end=start+minutes*60000;
    const relevant=state.history.filter(b=>b.id===id && Date.parse(b.at)>=start && Date.parse(b.at)<end);
    const samples=relevant.reduce((a,b)=>a+Number(b.samples||0),0),fail=relevant.reduce((a,b)=>a+Number(b.failures||0),0),un=relevant.reduce((a,b)=>a+Number(b.unknowns||0),0);
    $('selectedInterval').innerHTML=`<div class="eyebrow">Recorded historical interval</div><h3>${esc(id)} · ${new Date(start).toLocaleString()}</h3><p class="desc">${samples} observed check(s), ${fail} failed, ${un} unknown. ${samples===0?'No result was observed for this interval.':'Based on retained RAM history; no availability is inferred between checks.'}</p>`;
  }
  function renderPaths(){
    const d=state.snapshot,rows=d?.exceptions||[];
    $('exceptionList').innerHTML=!d||!d.exceptionsReadable?'<div class="empty">DNSMasq upstream file is not available to the snapshot collector. Exceptions cannot be assessed.</div>':
      rows.length?rows.map(r=>`<div class="exception"><div><div class="muted">Matching domain scope</div><strong>${esc(r.domain)}</strong></div><div><div class="muted">Configured upstream</div><code>${esc(r.upstream)}</code></div><span class="warn-pill">Bypasses Stubby</span></div>`).join(''):
      '<div class="empty"><strong>No domain-scoped rules reported</strong>No matching DNSMasq exceptions found in the current readable upstream file. This does not establish that LAN devices cannot use other DNS paths.</div>';
  }
  function openInspector(id){const d=state.snapshot,r=(d?.resolvers||[]).find(x=>x.id===id);if(!r)return;
    $('inspectContent').innerHTML=`<h2>${esc(r.tls||r.id)} · ${esc(r.id)}</h2><p class="desc">Latest completed scheduled observation</p><div class="inspect-field"><span>Status</span><strong>${r.state==='ok'?'PASS':r.state==='fail'?'FAIL':'NOT OBSERVED'}</strong></div><div class="inspect-field"><span>DNS address</span><strong>${esc(r.ip)}:${esc(r.port)}</strong></div><div class="inspect-field"><span>TLS authentication</span><strong>${esc(r.tls)}</strong></div><div class="inspect-field"><span>Passed policy records</span><strong>${Number(r.policyPass||0)}</strong></div><div class="inspect-field"><span>Failed policy records</span><strong>${Number(r.policyFail||0)}</strong></div><p class="desc" style="margin-top:24px">The totals include repeated fast-confirmation probes where applicable. They are not unique DNS-policy counts.</p>`;
    $('inspectBackdrop').classList.add('open');$('inspector').classList.add('open');$('inspector').setAttribute('aria-hidden','false');$('inspectorClose').focus();
    // Embedded in Merlin's native page: bring the inspector into view when
    // a resolver card was clicked further down the router page.
    if(document.body.classList.contains('rg-embedded') && window.frameElement){
      try{window.frameElement.scrollIntoView({block:'start',behavior:'smooth'});}catch(e){}
    }
  }
  function closeInspector(){$('inspectBackdrop').classList.remove('open');$('inspector').classList.remove('open');$('inspector').setAttribute('aria-hidden','true');}
  function tab(name){state.tab=name;waveform.setVisible(name==='overview');syncWaveSignal(state.snapshot,state.feedConnected);document.querySelectorAll('[data-tab]').forEach(el=>{const active=el.dataset.tab===name;el.classList.toggle('active',active);});document.querySelectorAll('.tab').forEach(el=>el.classList.toggle('active',el.id===name));const m={overview:['Dashboard overview','Your DNS reliability, clearly visible.'],history:['Health history','Observed DNS reliability from volatile history.'],paths:['DNS paths & exceptions','Inspect DNSMasq domain-scoped Stubby bypasses.'],backups:['Backup & alternate resolvers','Manage ResolvGuard backup DoT endpoints, not ASUS WAN primary DNS.'],settings:['ResolvGuard settings','Configure monitoring thresholds and timing using Merlin authentication.']}[name];$('pageTitle').textContent=m[0];$('pageDesc').textContent=m[1];if(name==='history')renderHistory();if(name==='paths')renderPaths();if(name==='settings'||name==='backups')loadConfig();}
  async function load(url){const response=await fetch(url+'?t='+Date.now(),{cache:'no-store',credentials:'same-origin'});if(!response.ok)throw Error('HTTP '+response.status);const d=JSON.parse(await response.text());if(d.schema!==1)throw Error('Unsupported feed schema');return d;}
  async function refresh(){if(state.polling)return;state.polling=true;try{
      const d=await load('/ext/ResolvGuard/status.htm');
      const changed=!!d.lastEnd && d.lastEnd!==state.lastEnd;
      const first=state.snapshot===null;
      state.snapshot=d;state.lastFetch=Date.now();state.feedConnected=true;
      $('feedStatus').textContent='ROUTER FEED · '+(isStale(d)?'STALE':'CONNECTED');
      $('feedStatus').classList.toggle('demo',isStale(d));
      state.historyAdvanced=false;
      if(changed&&!first){
        state.historyPending=d.lastEnd;
        state.historyBaseline=historySignature(state.history);
        state.historyAttempts=0;
      }
      // Retry only while awaiting a newly published history snapshot. If the
      // first read races the publisher, do not remain one heartbeat behind.
      if(first||changed||state.historyPending){
        try{
          const h=await load('/ext/ResolvGuard/history.htm');
          const incoming=Array.isArray(h.buckets)?h.buckets:[];
          const oldSignature=historySignature(state.history);
          const newSignature=historySignature(incoming);
          state.history= incoming;
          if(!first && newSignature!==oldSignature)state.historyAdvanced=true;
          if(state.historyPending){
            state.historyAttempts++;
            if(newSignature!==state.historyBaseline || state.historyAttempts>=8){
              state.historyPending='';state.historyAttempts=0;
            }
          }
        }catch(e){
          console.warn('ResolvGuard history unavailable:',e.message);
          if(state.historyPending && ++state.historyAttempts>=8){state.historyPending='';state.historyAttempts=0;}
        }
      }
      state.lastEnd=d.lastEnd||'';
      // Keep the heartbeat tied solely to completed checks. The history can
      // refresh separately after status without inventing another beat.
      renderOverview();if(state.tab==='history')renderHistory();if(state.tab==='paths')renderPaths();
      if(changed&&!first&&!isStale(d))pulseCompletedCheck();
    }catch(e){
      state.feedConnected=false;
      $('feedStatus').textContent='ROUTER FEED · UNAVAILABLE';$('feedStatus').classList.add('demo');
      syncWaveSignal(state.snapshot,false);
      $('heroHeading').textContent='Cannot load ResolvGuard data.';
      $('heroText').textContent='The WebUI data feed is unavailable. No health state is assumed. Confirm the WebUI publisher is installed and a scheduled check has completed.';
      console.warn('ResolvGuard feed:',e.message);
    }finally{state.polling=false;}
  }
  document.addEventListener('click',e=>{
    const t=e.target.closest('[data-tab]');if(t){tab(t.dataset.tab);return;}
    const b=e.target.closest('[data-bin]');if(b){tab('history');selectBin(b.dataset.resolver,b.dataset.period,Number(b.dataset.bin));$('selectedInterval').scrollIntoView({behavior:'smooth',block:'center'});return;}
    const r=e.target.closest('[data-resolver]');if(r)openInspector(r.dataset.resolver);
  });
  // A real manual health check uses the native ASUS authentication/session and
  // service-event hook. The result feed is separate from scheduled monitoring.
  const manualUrl='/ext/ResolvGuard/manual.htm';
  async function manualFeed(){
    try{return await load(manualUrl);}catch(e){return null;}
  }
  function manualStatus(title,message,html){
    $('manualPanel').hidden=false;
    $('manualTitle').textContent=title;
    $('manualSummary').textContent=message;
    $('manualResults').innerHTML=html||'';
  }
  function manualFinish(){
    state.manualBusy=false;
    $('runHealthCheck').disabled=false;
    $('runHealthCheck').textContent='Run Health Check';
    if(state.manualPolling!==null){clearInterval(state.manualPolling);state.manualPolling=null;}
  }
  function renderManual(data){
    if(data.status==='running'){
      manualStatus('Health check running','Authenticated DoT queries are being evaluated against the current policy.',
        '<span class="manual-inline-busy"></span>Probing configured DNS resolvers…');
      return;
    }
    if(data.status==='error'){
      manualStatus('Health check could not complete',data.message||'A router-side error interrupted the manual evaluation.',
        '<p class="manual-status amber">Not completed</p>');
      manualFinish();return;
    }
    if(data.status!=='complete')return;
    const passed=Number(data.passed||0),failed=Number(data.failed||0);
    const rs=Array.isArray(data.resolvers)?data.resolvers:[];
    const checks=Array.isArray(data.checks)?data.checks:[];
    const allPass=failed===0&&passed>0;
    let html=`<p class="manual-status ${allPass?'green':'amber'}">${allPass?'All policy checks passed':failed+' policy check(s) failed'}</p>`;
    html+=`<p class="desc">${passed} passed · ${failed} failed · Completed ${esc(new Date(Number(data.completedEpoch)*1000).toLocaleString())}</p>`;
    html+='<div class="manual-grid">'+rs.map(r=>`<div class="manual-item"><strong>${esc(r.id)} — <span class="${Number(r.failed)?'amber':'green'}">${Number(r.failed)?'FAILED':'PASS'}</span></strong><small>${esc(r.ip)}:${esc(r.port)} · ${esc(r.tls)}</small><small>${Number(r.passed)||0} passed · ${Number(r.failed)||0} failed</small></div>`).join('')+'</div>';
    html+='<div class="manual-log">'+rs.map(r=>`<details><summary>${esc(r.id)} — ${Number(r.passed)||0} passed / ${Number(r.failed)||0} failed</summary>${checks.filter(c=>c.id===r.id).map(c=>`<div class="manual-check"><span class="${c.result==='PASS'?'pass':'fail'}">${esc(c.result)}</span> ${esc(c.hostname)} ${esc(c.type)}<div class="desc">${esc(c.detail||'')}</div></div>`).join('')}</details>`).join('')+'</div>';
    manualStatus('Manual health check complete','Results of independently authenticated DNS-over-TLS queries.',html);
    manualFinish();
  }
  async function pollManual(){
    if(!state.manualBusy)return;
    if(Date.now()-state.manualRequestedAt>300000){
      manualStatus('Health check timeout','The router did not publish a completed result within five minutes. Inspect the router log.',
        '<p class="manual-status amber">Timed out</p>');
      manualFinish();return;
    }
    const d=await manualFeed();
    if(!state.manualBusy)return;
    if(d && d.requestId && d.requestId!==state.manualPreviousId){
      state.manualRunId=d.requestId;
      renderManual(d);
      return;
    }
    if(Date.now()-state.manualRequestedAt>15000 && !state.manualRunId){
      manualStatus('Health check was not started','No new router-side request appeared. Verify the service-event hook and browser authentication.',
        '<p class="manual-status amber">Request not received</p>');
      manualFinish();
    }
  }
  async function runManualHealthCheck(){
    if(state.manualBusy)return;
    state.manualBusy=true;state.manualRunId='';
    $('runHealthCheck').disabled=true;
    $('runHealthCheck').textContent='Checking…';
    manualStatus('Starting manual health check','This checks the configured policy through independent authenticated DoT probes.',
      '<span class="manual-inline-busy"></span>Sending request to the router…');
    const old=await manualFeed();
    state.manualPreviousId=old?.requestId||'';
    state.manualRequestedAt=Date.now();
    try{
      if(window.parent===window || typeof window.parent.rgRequestManualCheck!=='function' || !window.parent.rgRequestManualCheck())
        throw Error('Open the dashboard through WAN → ResolvGuard to use the authenticated ASUS service action.');
    }catch(e){
      manualStatus('Cannot run health check',e.message,'<p class="manual-status amber">Not started</p>');
      manualFinish();return;
    }
    state.manualPolling=setInterval(pollManual,1500);
    pollManual();
  }
  // The authenticated parent page submits configuration requests through
  // Merlin's standard start_apply.htm action and owned service-event hook.
  const settingsDefs={
    SCHEDULE_INTERVAL_MINUTES:['Schedule interval (minutes)',[1,2,5,10,15,20,30,60]],
    FAST_CONFIRM_SECONDS:['Fast failure confirmation (seconds)',[0,15]],
    FAIL_THRESHOLD:['Failure threshold',[1,20]],
    RECOVERY_THRESHOLD:['Recovery threshold',[1,20]],
    TIMEOUT_SECONDS:['DoT query timeout (seconds)',[1,15]],
    BOOT_MIN_UPTIME_SECONDS:['Startup warmup (seconds)',[0,3600]],
    SYSLOG_HEALTH_INTERVAL_MINUTES:['Healthy syslog interval (minutes)',[0,15,30,60]]
  };
  function configNotice(msg,isError=false){const e=$('configFeedback');e.hidden=false;e.textContent=msg;e.classList.toggle('error',isError);}
  // Loading a read-only snapshot must not mark the UI as performing a write.
  // Otherwise the first load leaves every configuration button disabled.
  function syncConfigControls(){
    const disabled=state.configBusy||state.configLoading||!state.config||!state.configFresh;
    document.querySelectorAll('#backups button,#settingsRows button').forEach(e=>e.disabled=disabled);
  }
  function controlsBusy(b){state.configBusy=Boolean(b);syncConfigControls();}
  function renderSettings(){
    const cfg=state.config;if(!cfg)return;
    var summary=cfg.monitoringEnabled?'Monitoring enabled'+(cfg.autoFailoverEnabled?' · Automatic failover authorization exists':' · Monitoring only'):'Monitoring disabled';
    $('settingsSummary').textContent=summary+(cfg.generatedEpoch?' · Router snapshot: '+new Date(Number(cfg.generatedEpoch)*1000).toLocaleString():'');
    $('settingsRows').innerHTML=Object.entries(settingsDefs).map(([key,[title,options]])=>{
      const val=Number(cfg.settings?.[key]||0),list=options.length>2||['SCHEDULE_INTERVAL_MINUTES','SYSLOG_HEALTH_INTERVAL_MINUTES'].includes(key);
      const input=list?`<select class="rg-input" id="s_${key}">${options.map(n=>`<option value="${n}"${n===val?' selected':''}>${n}</option>`).join('')}</select>`:
        `<input class="rg-input" type="number" id="s_${key}" min="${options[0]}" max="${options[1]}" step="1" value="${val}">`;
      return `<div class="rg-setting-row"><label for="s_${key}">${esc(title)}</label><div class="rg-control">${input}<button type="button" class="btn rg-save-setting" data-setting="${key}"${state.configBusy?' disabled':''}>Apply</button></div></div>`;
    }).join('');
  }
  function resetBackup(){state.editingBackupId='';$('backupId').disabled=false;for(const id of ['backupId','backupIp','backupTls'])$(id).value='';$('backupPort').value='853';$('backupMode').textContent='Add new resolver';$('backupSave').textContent='Save resolver';}
  function renderBackups(){
    const cfg=state.config;if(!cfg)return;
    const rs=Array.isArray(cfg.backups)?cfg.backups:[];
    $('backupCount').textContent=rs.length+' configured';
    $('backupPoolState').textContent='Active pool: '+(state.snapshot?.pool||'unknown');
    const groups=new Map();for(const r of rs){const key=r.tls+':'+r.port;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r.id);}
    $('backupGroups').innerHTML='<div class="card-title">Candidate alternate groups</div><p class="desc">Grouped by identical TLS hostname and port. These are configuration candidates, not proof of successful health checks.</p>'+
      (groups.size?[...groups].map(([key,ids])=>`<div class="rg-backup-info" style="padding:8px 0"><strong>${esc(key)}</strong><small>${esc(ids.join(', '))}</small></div>`).join(''):'<p class="desc">No alternate resolver groups configured.</p>');
    $('backupRows').innerHTML=rs.length?rs.map(r=>`<div class="rg-backup-row"><div class="rg-backup-info"><strong>${esc(r.id)} · ${esc(r.tls)}</strong><small>${esc(r.ip)}:${Number(r.port)} · Configured backup · Not automatically health-verified</small></div><div class="rg-actions" style="margin-top:0"><button type="button" class="btn rg-backup-edit" data-id="${esc(r.id)}">Edit</button><button type="button" class="btn rg-backup-delete" data-id="${esc(r.id)}">Remove</button></div></div>`).join(''):'<div class="empty">No ResolvGuard backup endpoints configured. Preferred WAN resolvers are managed in ASUS WAN settings.</div>';
    syncConfigControls();
  }
  // Reading a page or opening a tab must never issue an ASUS firmware apply.
  // The router publishes this RAM-only snapshot after installs, scheduled
  // checks and successful SSH/WebUI configuration commits. Fetch it without
  // caching, preserving existing revision checks after a confirmed write.
  async function loadConfig(afterRevision=0){
    if(state.configLoading)return false;
    state.configLoading=true;state.configFresh=false;syncConfigControls();
    try{
      const deadline=Date.now()+6000;
      let current=null;
      do {
        try {
          const d=await load('/ext/ResolvGuard/config.htm');
          if(d.kind!=='configuration'||!Number.isSafeInteger(d.revision)||d.revision<1)
            throw Error('Invalid configuration revision');
          if(d.revision>afterRevision){current=d;break;}
        } catch(e) { /* Snapshot may not have been published yet. */ }
        await new Promise(resolve=>setTimeout(resolve,750));
      } while(Date.now()<deadline);
      if(!current)throw Error(afterRevision>0?
        'The router confirmed the save but did not publish a newer configuration snapshot. Editing is disabled.':
        'No router configuration snapshot is available. Editing is disabled.');
      state.config=current;state.configFresh=true;
      renderSettings();renderBackups();
      if(afterRevision===0)$('configFeedback').hidden=true;
      return true;
    }catch(e){
      state.configFresh=false;
      configNotice(e.message||'Configuration is unavailable; changes disabled.',true);
      if(!state.config)$('settingsSummary').textContent='Configuration unavailable';
      return false;
    }finally {state.configLoading=false;syncConfigControls();}
  }
  function configPayload(parts){
    // All fields are ASCII data, not shell instructions. Values are revalidated
    // by the router using the same helpers as the SSH interface.
    if(parts.some(p=>!(/^[A-Za-z0-9_.:/_-]+$/.test(String(p)))))throw Error('Only plain ASCII DNS values are accepted');
    return String(Date.now())+String(Math.floor(Math.random()*1000)).padStart(3,'0')+'|'+parts.join('|');
  }
  async function applyConfig(parts){
    if(state.configBusy||!state.config||!state.configFresh)return;
    let payload;try{payload=configPayload(parts);}catch(e){configNotice(e.message,true);return;}
    const requestId=payload.split('|')[0];
    const previousRevision=Number(state.config.revision||0);
    controlsBusy(true);configNotice('Submitting configuration request to Merlin…');
    try {
      if(window.parent===window || typeof window.parent.rgRequestConfiguration!=='function' || !window.parent.rgRequestConfiguration(payload))
        throw Error('Open this page through WAN → ResolvGuard to use authenticated settings.');
      const began=Date.now();let received=null;
      while(Date.now()-began<25000){
        await new Promise(resolve=>setTimeout(resolve,1000));
        try{const d=await load('/ext/ResolvGuard/config-action.htm');if(d.requestId===requestId){received=d;break;}}catch(e){}
      }
      if(!received)throw Error('No matching response from the router. Check /tmp/resolvguard-webui-config.log; do not assume the setting was saved.');
      if(received.status!=='success')throw Error(received.message||'The router rejected the configuration request.');
      configNotice(received.message||'Configuration saved');
      if(!await loadConfig(previousRevision))
        configNotice('Router confirmed the save, but the new configuration snapshot is unavailable. Further edits are disabled until refreshed.',true);
      resetBackup();
    }catch(e){configNotice(e.message,true);}finally{
      controlsBusy(false);
      // The firmware may keep its 'Complete' overlay after the action has
      // already finished. Never leave a blocking spinner over the dashboard.
      try { if(window.parent!==window && typeof window.parent.rgFinishConfiguration==='function') window.parent.rgFinishConfiguration(); }catch(e){}
    }
  }
  $('backupReset').addEventListener('click',resetBackup);
  $('backupSave').addEventListener('click',()=>{
    const id=$('backupId').value.trim(),ip=$('backupIp').value.trim(),tls=$('backupTls').value.trim(),port=$('backupPort').value.trim();
    if(!/^[A-Za-z0-9_-]{1,32}$/.test(id)||/^wan[0-9]+$/.test(id)||!ip||!tls||!/^\d{1,5}$/.test(port)||Number(port)<1||Number(port)>65535){configNotice('Enter a valid backup ID, IP, TLS name and port.',true);return;}
    applyConfig([state.editingBackupId?'backup-edit':'backup-add',id,ip,tls,port]);
  });
  document.addEventListener('click',e=>{
    const setting=e.target.closest('.rg-save-setting');if(setting){const key=setting.dataset.setting;const val=$('s_'+key).value;
      if(!/^\d+$/.test(val)){configNotice('Enter a valid numeric value.',true);return;}
      const options=settingsDefs[key]?.[1];if(!options)return;
      const v=Number(val);if(options.length===2?(v<options[0]||v>options[1]):!options.includes(v)){configNotice('Value outside allowed range.',true);return;}
      applyConfig(['setting',key,val]);return;}
    const preset=e.target.closest('[data-preset]');if(preset){if(confirm('Add both endpoints of this backup resolver preset?'))applyConfig(['preset',preset.dataset.preset]);return;}
    const edit=e.target.closest('.rg-backup-edit');if(edit){const r=state.config?.backups?.find(x=>x.id===edit.dataset.id);if(!r)return;
      state.editingBackupId=r.id;$('backupId').value=r.id;$('backupId').disabled=true;$('backupIp').value=r.ip;$('backupTls').value=r.tls;$('backupPort').value=r.port;
      $('backupMode').textContent='Editing '+r.id;$('backupSave').textContent='Update resolver';return;}
    const remove=e.target.closest('.rg-backup-delete');if(remove&&confirm('Remove backup resolver '+remove.dataset.id+'? This may require a new policy approval.'))applyConfig(['backup-delete',remove.dataset.id]);
  });
  loadConfig();
  $('runHealthCheck').addEventListener('click',runManualHealthCheck);
  $('manualClose').addEventListener('click',()=>{$('manualPanel').hidden=true;});
  $('period').addEventListener('change',e=>{state.period=e.target.value;renderHistory();});
  $('inspectorClose').addEventListener('click',closeInspector);$('inspectBackdrop').addEventListener('click',closeInspector);
  document.addEventListener('keydown',e=>{if(e.key==='Escape')closeInspector();});
  setInterval(()=>{
    const d=state.snapshot;const period=Number(d?.scheduleMinutes||1)*60;
    $('statCountdown').textContent=d?.lastEnd ? Math.max(0,Math.floor((Date.parse(d.lastEnd)+period*1000-Date.now())/1000))+'s' : '—';
    if(d&&isStale(d)){$('feedStatus').textContent='ROUTER FEED · STALE';$('feedStatus').classList.add('demo');}
    if(d)syncWaveSignal(d,state.feedConnected);
  },1000);
  setInterval(refresh,8000);
  renderPaths();refresh();
})();

</script>
</template>
</body>
</html>
