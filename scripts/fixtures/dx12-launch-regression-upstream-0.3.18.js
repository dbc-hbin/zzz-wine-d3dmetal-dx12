/*
 * Minimal executable Yaagl 0.3.18 fixture.
 *
 * Verbatim upstream sections: oc, V_, CS, and Ht from
 * resources_napos.neu!dist/assets/index.6abd63f7.js (SHA-256
 * 98b4052c999751d631d12cae834a8a41484f2447061893c9b44a6e63e36b8d1e).
 * The catalog is a historical local Wine menu snapshot: three existing
 * D3DMetal records intentionally omit attributes.id, as Yaagl records do.
 * K_ below is the verbatim D3D12 storage lifecycle from the installed
 * resources.neu dist/assets/index.2a92d5e0.js, separate from those
 * Yaagl 0.3.18 launch sections.
 */

const bl="config_use_d3d12";async function K_({locale:e,config:t,wine:n}){try{t.useD3D12=await we(bl)=="true"}catch{t.useD3D12=!1}const[r,u]=le(t.useD3D12);async function o(i){return ke(t.useD3D12),i?(t.useD3D12==r()||(t.useD3D12=r(),await he(bl,t.useD3D12?"true":"false")),pe):(u(t.useD3D12),pe)}return De(()=>{r(),o(!0)}),[function(){return E(Ue,{id:"d3d12",get children(){return E(Ee,{get children(){return E(bt,{get checked(){return r()},get disabled(){return n.attributes.supportsD3d12!==!0},onChange:()=>u(a=>!a),size:"md",get children(){return e.get("SETTING_D3D12")}})}})}})}]}

async function Ht(e,t){return await $e(["mv","-f",`${Y(e)}`,`${Y(t)}`])}

async function oc(e){const t=await E4();async function n(h,f){return await r("cmd",[h,...f])}async function r(h,f,C,_=void 0){return await $e(h=="copy"?[t,"cmd","/c",h,...f]:[t,h,...f],{...a(),...C!=null?C:{}},!1,_)}async function o(h,f,C,_=void 0){return await Fr(h=="copy"?[t,"cmd","/c",h,...f]:[t,h,...f],{...a(),...C!=null?C:{}},!1,_)}async function u(){return await Fr([H.join(H.dirname(t),"wineserver"),"-w"],{...a()})}function i(h){return"Z:"+`${h}`.replaceAll("/","\\")}function a(){return{WINEDEBUG:"fixme-all,err-unwind,+timestamp",WINEPREFIX:e.prefix}}async function s({gameDir:h}){return await Fr(["osascript","-e",["tell","app",'"Terminal"',"to","do","script",`"${hr([t,"cmd"],{...a(),WINEPATH:i(h)}).replaceAll("\\","\\\\").replaceAll('"','\\"')}"`].join(" "),"-e",["tell","app",'"Terminal"',"to","activate"].join(" ")],{},!1,"/dev/null")}let c;try{c=await Le("wine_netbiosname")}catch{c=`DESKTOP-${Vl(7)}`,await ge("wine_netbiosname",c)}async function l(h){const f=`@echo off
cd "%~dp0"
reg add "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d ${h.retina?"y":"n"} /f
reg add "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v LeftCommandIsCtrl /t REG_SZ /d ${h.leftCmd?"y":"n"} /f
`;await Ut(Y("winedrv_config.bat"),f),await r("cmd",["/c",`${i(Y("./winedrv_config.bat"))}`],{},"/dev/null"),await u()}async function d(){const h=`@echo off
cd "%~dp0"
reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
reg add "HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore" /v FullPath /t REG_SZ /d "C:\\Windows\\System32" /f
`;await Ut(Y("winedrv_config.bat"),h),await r("cmd",["/c",`${i(Y("./winedrv_config.bat"))}`],{},"/dev/null"),await u()}return{exec:r,exec2:o,waitUntilServerOff:u,cmd:n,toWinePath:i,prefix:e.prefix,openCmdWindow:s,setProps:l,setNVExtension:d,attributes:{...e.distro.attributes}}}

async function*V_({gameDir:e,gameExecutable:t,wine:n,config:r,server:o}){yield["setUndeterminedProgress"],yield["setStateText","PATCHING"],await z_(n,o),await n.setProps(r);const u=[];r.resolutionCustom&&(u.push("-screen-width",r.resolutionWidth),u.push("-screen-height",r.resolutionHeight),u.push("-screen-fullscreen","0"));const i=`@echo off
cd "%~dp0"
copy "${n.toWinePath(H.join(e,atob("SG9Zb0tQcm90ZWN0LnN5cw==")))}" "%WINDIR%\\system32\\"
cd /d "${n.toWinePath(e)}"
"${n.toWinePath(H.join(e,t))}" ${u.join(" ")}`;await Ut(Y("config.bat"),i),yield*O_(e,n,o,r),await Mt(Y("./logs"));const a=Y("./");try{yield["setStateText","GAME_RUNNING"];const s=Y(`./logs/game_${Date.now()}.log`);if(r.blockNet){const c="/tmp/yaagl_network_block_script.sh",d=["#!/bin/sh",'HOSTS_FILE="/etc/hosts"',`ENTRY="0.0.0.0 ${o.id=="nap_global"?G_:H_}"`,'PAD_START="# Temporarily Added by Yaagl"','PAD_END="# End of section"','if ! grep -qF "$ENTRY" "$HOSTS_FILE"; then',`sudo bash -c "echo -e '$PAD_START
$ENTRY
$PAD_END' >> '/etc/hosts'"`,"fi","sleep 20",'sudo sed -i.bak "/$PAD_START/,/$PAD_END/d" "$HOSTS_FILE"',`rm ${c}`];await Ut(c,d.join(`
`)),await $e(["osascript","-e",`do shell script "source ${c} > /dev/null 2>&1 &" with administrator privileges`],{},!1)}await n.exec2(r.steamPatch?"C:\\windows\\system32\\steam.exe":"cmd",r.steamPatch?[n.toWinePath(H.join(e,t))]:["/c",`${n.toWinePath(Y("./config.bat"))} `],{MTL_HUD_ENABLED:r.metalHud?"1":"",WINEDLLOVERRIDES:"",WINE_ENABLE_TIMEOUT_FIX:r.timeoutFix?"1":"0",...n.attributes.renderBackend=="dxmt"?{WINEMSYNC:"1",DXMT_LOG_PATH:a,DXMT_CONFIG_FILE:H.join(a,"dxmt.conf"),GST_PLUGIN_FEATURE_RANK:"atdec:MAX,avdec_h264:MAX"}:{WINEESYNC:"1"},...r.proxyEnabled?{HTTP_PROXY:r.proxyHost,HTTPS_PROXY:r.proxyHost}:{}},s),await n.waitUntilServerOff(),r.resolutionCustom&&await j_(n,o)}catch(s){await Ve(String(s))}await ct(Y("config.bat")),yield["setStateText","REVERT_PATCHING"],yield*xd(e,n,o,r)}

async function CS({aria2:e,wineAbsPrefix:t,wineDistro:n,locale:r}){async function*o(){const u=Y("./wine");await Gr(t),yield["setStateText","DOWNLOADING_ENVIRONMENT"];const i=n.remoteUrl.endsWith(".xz"),a=Y("./wine.tar."+(i?"xz":"gz"));for await(const l of e.doStreamingDownload({uri:n.remoteUrl,absDst:a}))yield["setProgress",Number(l.completedLength*BigInt(100)/l.totalLength)],yield["setStateText","DOWNLOADING_ENVIRONMENT_SPEED",`${ot(Number(l.downloadSpeed))}`];yield["setStateText","EXTRACT_ENVIRONMENT"],yield["setUndeterminedProgress"],await Gr(u),await $e(["mkdir","-p",u]),n.attributes.winePath?await kl(Y("./wine.tar."+(i?"xz":"gz")),u,n.attributes.winePath,i):await Tf(Y("./wine.tar."+(i?"xz":"gz")),u),await ct(a),yield["setStateText","CONFIGURING_ENVIRONMENT"],await mS(u),await Gf("com.apple.quarantine",u),yield["setStateText","CONFIGURING_ENVIRONMENT"],yield["setUndeterminedProgress"],await dS(P_);const s=await oc({prefix:t,distro:n});await s.exec("wineboot",["-u"],{},"/dev/null"),await s.exec("winecfg",["-v","win10"],{},"/dev/null"),(String("napos").startsWith("bh3")||String("napos").startsWith("cbjq"))&&(yield*pS(e,s)),await ge("wine_state","ready"),await ge("wine_tag",n.id),await ge("wine_update_url",null),await ge("wine_update_tag",null);const c=`DESKTOP-${Vl(7)}`;await ge("wine_netbiosname",c),yield["setStateText","INSTALL_DONE"]}return Fd(r,o)}

const _S=[{"id":"11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-gptk4b2-arm64server","displayName":"Wine 11.17 ZZZ DX12 tuned stage parallel cache warmup (GPTK 4.0b2)","remoteUrl":"file:///safe/wine-11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-gptk4b2-arm64server.tar.xz","attributes":{"renderBackend":"d3dmetal","winePath":"wine"}},{"id":"11.17-p3-safe-msync","displayName":"Wine 11.17 P3 safe msync","remoteUrl":"file:///safe/wine-11.17-p3-safe-msync.tar.xz","attributes":{"renderBackend":"d3dmetal","winePath":"wine"}},{"id":"11.17-zzz-dx12-tuned-stage-parallel-gptk4b2-arm64server","displayName":"Wine 11.17 ZZZ DX12 tuned stage parallel (GPTK 4.0b2)","remoteUrl":"file:///safe/wine-11.17-zzz-dx12-tuned-stage-parallel-gptk4b2-arm64server.tar.xz","attributes":{"renderBackend":"d3dmetal","winePath":"wine"}}];

async function fixtureUpdater(){await Ht("./resources.neu.update","./resources.neu")}
