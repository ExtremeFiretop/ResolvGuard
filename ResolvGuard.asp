<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<!-- ResolvGuard WebUI Integration v2.9 (Merlin native shell + manual read-only probe action) -->
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
/* Keep ASUS navigation and page chrome; isolate ResolvGuard's visual theme in an iframe. */
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
  var page=window.location.pathname.split("/").pop();
  form.elements.namedItem("current_page").value=page;
  form.elements.namedItem("next_page").value=page;
  form.submit();
  return true;
}
function initial() {
  if (typeof show_menu === 'function') show_menu();
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
  <iframe id="rg_dashboard" title="ResolvGuard dashboard" scrolling="auto" onload="rgDashboardLoaded()" src="/ext/ResolvGuard/dashboard.htm?embedded=1"></iframe>
</div>
</td></tr></tbody></table>
</td></tr></table>
</td><td width="10"></td></tr></table>
<!-- The native ASUS page owns the authenticated service action submission.
     The embedded dashboard cannot execute shell code or send arbitrary commands. -->
<iframe name="rg_command_frame" id="rg_command_frame" title="ResolvGuard command response" style="display:none;width:0;height:0;border:0" aria-hidden="true"></iframe>
<form id="rg_manual_form" name="form" method="post" action="start_apply.htm" target="rg_command_frame" style="display:none">
  <input type="hidden" name="action_script" value="start_ResolvGuardManualCheck" />
  <input type="hidden" name="action_mode" value="apply" />
  <input type="hidden" name="action_wait" value="0" />
  <input type="hidden" name="current_page" value="" />
  <input type="hidden" name="next_page" value="" />
  <input type="hidden" name="modified" value="0" />
</form>
<div id="footer"></div>
</body>
</html>
