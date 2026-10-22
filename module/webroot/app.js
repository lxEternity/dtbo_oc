// SPDX-License-Identifier: Apache-2.0
import { exec } from './vendor/kernelsu.js';

const $ = id => document.getElementById(id);
const COMMAND = 'sh /data/adb/modules/dtbo_oc/bin/webuictl.sh';
let state = null;
let busy = false;
let rmBusy = false;
let apBusy = false;
let connected = false;
let dirty = false;
let sel = { hz: null, oc_mode: null, ltpo_off: null };

function notify(message, isError = false) {
  const box = $(isError ? 'error' : 'notice');
  $(isError ? 'notice' : 'error').hidden = true;
  box.textContent = message;
  box.hidden = !message;
}

function rmNotify(message) {
  const box = $('rm-notice');
  box.textContent = message;
  box.hidden = !message;
}

async function command(args, timeoutMs = 60000) {
  if (!window.ksu || typeof window.ksu.exec !== 'function') {
    throw new Error('请从 KernelSU 管理器打开本模块的 WebUI。');
  }
  let timeoutId;
  try {
    const result = await Promise.race([
      exec(`${COMMAND} ${args}`),
      new Promise((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error('请求超时, 请稍后刷新当前状态。')), timeoutMs);
      }),
    ]);
    let data;
    try { data = JSON.parse(result.stdout.trim()); }
    catch { throw new Error('无法读取控制接口的返回结果, 请确认模块已安装并重启。'); }
    if (Number(result.errno) !== 0 && data.ok) throw new Error('控制接口执行失败, 请刷新当前状态。');
    if (!data || data.ok !== true) throw new Error(data?.message || '操作失败。');
    return data;
  } finally {
    clearTimeout(timeoutId);
  }
}

function battActive(b = state?.batt) {
  return !!(b && (Number(b.limit) || Number(b.uncap) || Number(b.mod) || Number(b.full_on)));
}

function licBlocked() {
  const licOk = state?.license?.state === 'ok';
  const needOC = (sel.hz ?? 0) > 0 || (sel.oc_mode === 'dtbo' && battActive());
  return !licOk && needOC;
}

function drawLicense() {
  const lic = state?.license;
  const box = $('verify-state');
  const okLic = lic?.state === 'ok';
  box.classList.toggle('ok', okLic);
  box.classList.toggle('bad', !okLic && !!lic);
  if (okLic) {
    $('verify-text').textContent = lic.expiry === '永久'
      ? '已验证Q群 永久'
      : `已验证Q群 期限${lic.expiry || '未知'}`;
    $('verify-caption').textContent = '已验证';
  } else if (lic?.state === 'expired') {
    $('verify-text').textContent = `授权已过期 (QQ ${lic.qq || ''}), 请重新验证`;
    $('verify-caption').textContent = '已过期';
  } else if (lic?.state === 'wrongmachine') {
    $('verify-text').textContent = `授权绑定于其他设备 (QQ ${lic.qq || ''}), 请在本机重新验证`;
    $('verify-caption').textContent = '设备不符';
  } else if (lic?.state === 'bad') {
    $('verify-text').textContent = '授权文件无效, 请重新验证';
    $('verify-caption').textContent = '无效';
  } else {
    $('verify-text').textContent = '未验证 — 使用超频/刷入功能需先验证已加入QQ群';
    $('verify-caption').textContent = '未验证';
  }
  $('machine-id').textContent = state?.machine || '—';
}

function controls() {
  const ready = connected && state && !busy;
  const blocked = licBlocked();
  document.body.classList.toggle('busy', busy);
  $('refresh').disabled = busy;
  $('apply').disabled = !ready || blocked;
  $('apply-label').textContent = busy ? '正在处理…' : blocked ? '需先完成QQ群验证' : '保存并应用';
  const hzText = sel.hz === 0 ? '不超频' : sel.hz ? `${sel.hz}Hz` : '—';
  const modeText = sel.oc_mode === 'ko' ? 'KO 挂载' : sel.oc_mode === 'dtbo' ? 'DTBO 补丁' : '—';
  $('selection').textContent = `${hzText} · ${modeText}`;
  $('restore').disabled = !ready || busy;
}

function radioButton(className, label, checked, onClick, disabled = false) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = className;
  button.setAttribute('role', 'radio');
  button.setAttribute('aria-label', label);
  button.setAttribute('aria-checked', String(checked));
  button.disabled = disabled;
  button.tabIndex = checked ? 0 : -1;
  button.addEventListener('click', onClick);
  return button;
}
function span(className, text) {
  const element = document.createElement('span');
  element.className = className;
  element.textContent = text;
  return element;
}

// 方案高亮: 精确匹配优先; 已保存值非方案值 (旧版档位值) 时就近映射, 仅影响显示
function planHighlight(hz, plans) {
  if (!plans.length) return 0;
  if (plans.includes(hz)) return hz;
  let best = plans[plans.length - 1];
  for (const p of plans) { if (p >= hz) { best = p; break; } }
  return best;
}

function drawRates() {
  const fragment = document.createDocumentFragment();
  const plans = (state?.plans || []).slice().sort((a, b) => a - b);
  const gears = state?.choices || [];
  if (!state?.oc_capable || !plans.length) {
    sel.hz = 0;
    $('rates-caption').textContent = '本机型不支持超频';
    const off = radioButton('rate-choice wide', '不超频', true, () => {});
    off.append(span('rate-number', '关'), span('rate-unit', 'OC'));
    $('rates').replaceChildren(off);
    return;
  }
  const hi = planHighlight(sel.hz, plans);
  plans.forEach(c => {
    const checked = hi === c;
    const b = radioButton('rate-choice overclock', `${c}Hz 超频方案`, checked, () => {
      sel.hz = c; dirty = true; drawRates(); controls();
    });
    b.append(span('rate-number', String(c)), span('rate-unit', 'Hz 方案'));
    fragment.append(b);
  });
  const off = radioButton('rate-choice stock', '不超频', sel.hz === 0, () => {
    sel.hz = 0; dirty = true; drawRates(); controls();
  });
  off.append(span('rate-number', '关'), span('rate-unit', 'OC'));
  fragment.append(off);
  $('rates').replaceChildren(fragment);
  const range = gears.length >= 2 ? `方案含 ${gears[0]}-${gears[gears.length - 1]} 全部档位`
    : gears.length === 1 ? `方案含 ${gears[0]} 档位` : '';
  $('rates-caption').textContent = range ? `${range} · 重启后生效` : '重启后生效';
}

function drawModes() {
  const fragment = document.createDocumentFragment();
  const koAvail = !!state?.ko?.available;
  {
    const dtbo = radioButton('mode-choice', 'DTBO 补丁', sel.oc_mode === 'dtbo', () => {
      sel.oc_mode = 'dtbo'; dirty = true; drawModes(); controls();
    });
    dtbo.append(span('m-title', 'DTBO 补丁'), span('m-detail', '生成超频 DTBO 并刷入, 重启后生效'));
    fragment.append(dtbo);
  }
  {
    const koWarn = state?.ko?.vermatch === 0;
    const ko = radioButton('mode-choice ko', 'KO 内核挂载', sel.oc_mode === 'ko', () => {
      sel.oc_mode = 'ko'; dirty = true;
      drawModes(); controls();
    });
    ko.append(span('m-title', 'KO 内核挂载'), span('m-detail', koWarn
      ? 'KO 与当前内核版本不匹配, OTA 后需等待模块更新'
      : !koAvail
        ? '未找到 KO 文件, 侧载到 /data/adb/dtbo_oc/ko/ 后重启生效'
        : state?.ko?.builtin
          ? '开机加载内置内核模块, 不动 DTBO, 重启生效'
          : '开机加载内核模块, 不动 DTBO, 重启生效'));
    fragment.append(ko);
  }
  $('modes').replaceChildren(fragment);
  $('mode-caption').textContent = sel.oc_mode === 'ko' ? 'KO 挂载' : 'DTBO 补丁';
}

function render(data) {
  state = data;
  connected = true;
  sel = { hz: data.hz, oc_mode: data.oc_mode, ltpo_off: data.ltpo_off };
  dirty = false;
  const plans = Array.isArray(data.plans) ? data.plans : [];
  const gears = Array.isArray(data.choices) ? data.choices : [];
  if (sel.hz > 0 && (plans.length || gears.length) && !plans.includes(sel.hz) && !gears.includes(sel.hz)) {
    notify(`已保存的 ${sel.hz}Hz 档位不适用于本机型, 请重新选择超频方案。`);
    sel.hz = 0;
    dirty = true;
  }
  $('connection').textContent = '已连接';
  $('connection').className = 'badge online';
  document.querySelector('.current-card').classList.add('connected');
  $('device-name').textContent = data.name || '未知机型';
  $('device-rate').textContent = data.maxrate ? `原厂最高 ${data.maxrate}Hz` : '';
  const curHz = data.hz === 0 ? '不超频' : String(data.hz);
  $('current-rate').textContent = curHz;
  $('current-rate-unit').textContent = data.hz === 0 ? '' : 'Hz';
  if (data.oc_mode === 'ko') {
    $('current-mode').textContent = 'KO 挂载';
    if (data.ko?.vermatch === 0) {
      $('current-detail').textContent = 'KO 与当前内核不匹配, 已拒绝加载';
    } else if (data.ko?.loaded) {
      $('current-detail').textContent = data.ko?.installed ? '已挂载并启用' : '已挂载 (状态待确认)';
    } else if (data.ko?.available) {
      $('current-detail').textContent = '待加载 (保存后重启生效)';
    } else {
      $('current-detail').textContent = '未找到 KO 文件';
    }
  } else {
    $('current-mode').textContent = 'DTBO 补丁';
    $('current-detail').textContent = data.dtbo_patched ? 'DTBO: 已修改' : 'DTBO: 原厂';
  }
  $('ltpo-off').checked = data.ltpo_off === 1;
  if (data.version) $('ver').textContent = data.version;
  drawLicense();
  drawRates();
  drawModes();
  if (!chgDirty) chgLoad(data.batt);
  else chgDraw();
  controls();
}

async function refresh(manual) {
  if (busy) return;
  busy = true;
  controls();
  try {
    render(await command('status'));
    $('error').hidden = true;
    if (manual) notify('已更新当前状态。');
  } catch (error) {
    connected = false;
    $('connection').textContent = '未连接';
    $('connection').className = 'badge offline';
    document.querySelector('.current-card').classList.remove('connected');
    notify(error.message, true);
  } finally {
    busy = false;
    controls();
  }
}

async function apply() {
  if (busy || !connected || !state) return;
  if (licBlocked()) {
    notify('请先完成QQ群验证: 在上方输入QQ号并点击验证。', true);
    return;
  }
  busy = true;
  controls();
  notify('正在保存配置并应用… (DTBO 方案包含解包/打包/刷入, 请稍候)');
  try {
    await command(`save hz=${sel.hz} oc_mode=${sel.oc_mode} ltpo_off=${sel.ltpo_off ? 1 : 0}`);
    const result = await command('apply', 120000);
    notify(result.message || '已应用, 重启后生效。');
    render(await command('status'));
  } catch (error) {
    notify(error.message, true);
    try { render(await command('status')); } catch { connected = false; }
  } finally {
    busy = false;
    controls();
  }
}

async function restore() {
  if (busy || !connected) return;
  busy = true;
  controls();
  notify('正在恢复原厂 DTBO / 卸载 KO…');
  try {
    const result = await command('restore', 90000);
    notify(result.message || '已恢复原厂。');
    render(await command('status'));
  } catch (error) {
    notify(error.message, true);
  } finally {
    busy = false;
    controls();
  }
}

async function verify(auto = false) {
  if (busy) return;
  let arg;
  if (auto) {
    arg = 'auto=1';
  } else {
    const qq = $('qq-input').value.trim();
    if (!/^[1-9][0-9]{4,10}$/.test(qq)) {
      notify('请输入正确的QQ号 (5-11位数字, 不以0开头)', true);
      return;
    }
    arg = `qq=${qq}`;
  }
  busy = true;
  controls();
  $('verify-btn').disabled = true;
  $('verify-auto-btn').disabled = true;
  notify(auto ? '正在自动检测本机QQ并联网验证…' : '正在联网验证QQ群成员身份…');
  try {
    await command(`verify ${arg}`, 120000);
    $('qq-input').value = '';
    render(await command('status'));
    notify('');
  } catch (error) {
    notify(error.message, true);
  } finally {
    busy = false;
    $('verify-btn').disabled = false;
    $('verify-auto-btn').disabled = false;
    controls();
  }
}

['rates', 'modes'].forEach(id => $(id).addEventListener('keydown', event => {
  if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
  const options = [...$(id).querySelectorAll('button:not(:disabled)')];
  const i = options.indexOf(event.target);
  if (i < 0 || !options.length) return;
  event.preventDefault();
  const direction = ['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 1;
  options[(i + direction + options.length) % options.length].click();
}));

$('ltpo-off').addEventListener('change', () => {
  sel.ltpo_off = $('ltpo-off').checked ? 1 : 0;
  dirty = true;
  controls();
});
$('refresh').addEventListener('click', () => refresh(true));
$('apply').addEventListener('click', apply);
$('restore').addEventListener('click', restore);
$('verify-btn').addEventListener('click', () => verify());
$('verify-auto-btn').addEventListener('click', () => verify(true));
$('qq-input').addEventListener('keydown', event => {
  if (event.key === 'Enter') verify();
});

// ================= 刷新率管理 (星驰引擎式) =================
// 数据: rm = {ready, globalRateId, appSwitchEnabled, appSwitchInterval, daemon, apps:{pkg:id}, rates:[{id,w,h,fps,type,base,ord}]}
let rm = null;
let rmEdit = null;      // 档位标注编辑副本 (rates 数组)
let rmDirty = false;
const appNames = {};

function rmSyncBusy() {
  const off = rmBusy;
  ['rm-scan', 'rm-unlock', 'rm-stop', 'rm-app-add', 'rm-rates-save'].forEach(id => { $(id).disabled = off; });
  $('rm-appsw').disabled = off;
  $('rm-intv').disabled = off;
  document.querySelectorAll('#rm-app-rows select, #rm-app-rows button, #rm-rates-list button, #rm-rates-list input').forEach(el => { el.disabled = off; });
}

async function rmAction(args, okMsg, timeoutMs = 60000) {
  if (rmBusy) return;
  rmBusy = true;
  rmSyncBusy();
  try {
    const result = await command(`ratectl ${args}`, timeoutMs);
    if (result.rm) {
      rm = result.rm;
      if (!rmDirty) rmEdit = null;
      rmDraw();
    }
    rmNotify(okMsg || result.message || '已保存。');
  } catch (error) {
    rmNotify(error.message, true);
  } finally {
    rmBusy = false;
    rmSyncBusy();
  }
}

function rmLoad() {
  rmNotify('');
  rmAction('status', '', 30000);
}

function rmScan() {
  rmAction('scan', '档位扫描完成。', 90000);
}

function rmToggleGlobal(id) {
  const cur = Number(rm?.globalRateId) || 0;
  if (cur === id) {
    rmAction('global id=0', '已解除全局锁定, 交还系统自动调频。');
  } else {
    const r = (rm?.rates || []).find(v => v.id === id);
    rmAction(`global id=${id}`, `已全局锁定 ${r ? r.fps : id}Hz。`);
  }
}

function rmDraw() {
  const rates = rm?.rates || [];
  const ready = rm?.ready === 1 && rates.length > 0;
  $('rm-empty').hidden = ready;
  ['rm-lock-heading', 'rm-app-heading', 'rm-rates-heading'].forEach(id => { $(id).closest('.rm-section').hidden = !ready; });
  if (!ready) {
    $('rm-sub').textContent = rm ? '未扫描档位' : '正在读取…';
    $('rm-entry-cap').textContent = '点击扫描导入档位表';
    return;
  }
  // 顶栏状态
  const gid = Number(rm.globalRateId) || 0;
  const lockR = rates.find(r => r.id === gid);
  const daemon = rm.daemon === 1;
  $('rm-sub').textContent = `${daemon ? '服务运行中' : '服务已停止'} · 共 ${rates.length} 档${lockR ? ` · 锁定 ${lockR.fps}Hz` : ''}`;
  $('rm-entry-cap').textContent = gid ? `已锁定 ${lockR ? lockR.fps : gid}Hz` : '全局锁定 · 按应用切换 · 档位标注';

  // ---- 全局锁定网格 ----
  const grid = $('rm-global-grid');
  const gfrag = document.createDocumentFragment();
  const sorted = [...rates].sort((a, b) => a.fps - b.fps || a.id - b.id);
  sorted.forEach(r => {
    const on = gid === r.id;
    const b = radioButton(`rm-choice${r.type === 'overclock' ? ' oc' : ''}${on ? ' on' : ''}`,
      `${r.fps}Hz ${r.type === 'overclock' ? '超频' : '原生'}`, on, () => rmToggleGlobal(r.id));
    b.append(span('rm-num', String(r.fps)), span('rm-unit', 'Hz'));
    const tag = span('rm-tag', r.type === 'overclock' ? '超' : '原');
    b.append(tag);
    gfrag.append(b);
  });
  grid.replaceChildren(gfrag);
  $('rm-lock-caption').textContent = lockR ? `已锁定 ${lockR.fps}Hz` : '未锁定 (系统自动调频)';
  $('rm-unlock').hidden = !gid;

  // ---- 按应用切换 ----
  $('rm-appsw').checked = rm.appSwitchEnabled === 1 || rm.appSwitchEnabled === true;
  const intv = Number(rm.appSwitchInterval) || 1;
  $('rm-intv').value = String(intv);
  $('rm-intv-v').textContent = String(intv);
  const appMap = rm.apps && typeof rm.apps === 'object' ? rm.apps : {};
  const pkgs = Object.keys(appMap);
  const rows = document.createDocumentFragment();
  pkgs.forEach(pkg => {
    const curId = Number(appMap[pkg]) || 0;
    const row = document.createElement('div');
    row.className = 'app-row';
    const name = span('app-name', appNames[pkg] || pkg);
    if (appNames[pkg] && appNames[pkg] !== pkg) name.append(span('app-pkg-sm', pkg));
    row.append(name);
    const select = document.createElement('select');
    select.className = 'app-hz';
    select.setAttribute('aria-label', `${pkg} 档位`);
    sorted.forEach(r => {
      const o = document.createElement('option');
      o.value = String(r.id);
      o.textContent = `${r.fps}Hz${r.type === 'overclock' ? ' · 超' : ''}`;
      if (r.id === curId) o.selected = true;
      select.append(o);
    });
    select.addEventListener('change', () => {
      const r = rates.find(v => v.id === Number(select.value));
      rmAction(`app set ${pkg} ${select.value}`, `已设置 ${appNames[pkg] || pkg} -> ${r ? r.fps : select.value}Hz。`);
    });
    row.append(select);
    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'rc-btn del';
    del.textContent = '移除';
    del.addEventListener('click', () => {
      rmAction(`app del ${pkg}`, `已移除 ${appNames[pkg] || pkg}。`);
    });
    row.append(del);
    rows.append(row);
  });
  if (!pkgs.length) {
    rows.append(span('app-empty', '尚未配置应用; 点「+ 添加应用」选择应用并设定其档位。'));
  }
  $('rm-app-rows').replaceChildren(rows);
  const appCap = [rm.appSwitchEnabled === 1 || rm.appSwitchEnabled === true ? '已开启' : '未开启'];
  appCap.push(`${pkgs.length} 个应用`);
  if (daemon) appCap.push('服务运行中');
  $('rm-app-caption').textContent = appCap.join(' · ');

  // ---- 档位标注 ----
  rmDrawAnnotate();
  rmSyncBusy();
}

function rmDrawAnnotate() {
  const list = $('rm-rates-list');
  const frag = document.createDocumentFragment();
  // 编辑副本: 首次渲染时从状态拷贝, 编辑仅改副本, 保存成功后丢弃
  if (!rmEdit) rmEdit = (rm?.rates || []).map(r => ({ ...r }));
  const rates = rmEdit;
  const groups = new Map();
  [...rates].sort((a, b) => a.fps - b.fps || a.id - b.id).forEach(r => {
    const key = `${r.w}x${r.h}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  });
  const redraw = () => { rmDrawAnnotate(); rmSyncBusy(); };
  groups.forEach((items, key) => {
    const gh = span('rm-res-title', `${key} · ${items.length} 档`);
    frag.append(gh);
    items.forEach(r => {
      const row = document.createElement('div');
      row.className = 'rm-rate-row' + (r.type === 'overclock' ? ' oc' : '');
      const num = span('rm-rate-num', String(r.fps));
      num.append(span('rm-unit', 'Hz'));
      row.append(num);
      // 类型: 星驰式 [原生|超频] 分段选择, 点「超频」即设为超频档
      const seg = span('rc-types', '');
      [['native', '原生'], ['overclock', '超频']].forEach(([t, label]) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'rc-seg' + (r.type === t ? ' on' : '') + (t === 'overclock' ? ' oc' : '');
        b.textContent = label;
        b.setAttribute('aria-pressed', r.type === t ? 'true' : 'false');
        b.addEventListener('click', () => {
          if (r.type === t) return;
          if (t === 'overclock' && r.base === 1) { rmNotify('该档是原生基准, 请先将基准改为其他原生档。', true); return; }
          r.type = t;
          if (t === 'native') r.ord = 0;
          else if (!r.ord) r.ord = 1;
          rmDirty = true;
          redraw();
        });
        seg.append(b);
      });
      row.append(seg);
      // 基准 (native 单选)
      const baseBtn = document.createElement('button');
      baseBtn.type = 'button';
      baseBtn.className = 'rc-btn' + (r.base === 1 ? ' on' : '');
      baseBtn.textContent = r.base === 1 ? '✓ 已设为原生基准' : '设为原生基准';
      baseBtn.disabled = r.type !== 'native';
      baseBtn.addEventListener('click', () => {
        rates.forEach(v => { if (v.w === r.w && v.h === r.h) v.base = 0; });
        r.base = 1;
        rmDirty = true;
        redraw();
      });
      row.append(baseBtn);
      // ord (仅超频档)
      if (r.type === 'overclock') {
        const ordWrap = span('rc-order', '');
        ordWrap.append(document.createTextNode('顺序'));
        const input = document.createElement('input');
        input.type = 'number';
        input.min = '1';
        input.max = '9';
        input.value = String(r.ord || 1);
        input.setAttribute('aria-label', `${r.fps}Hz 步进顺序`);
        input.addEventListener('change', () => {
          let n = parseInt(input.value, 10);
          if (!Number.isFinite(n) || n < 1) n = 1;
          if (n > 9) n = 9;
          r.ord = n;
          rmDirty = true;
          redraw();
        });
        ordWrap.append(input);
        row.append(ordWrap);
      }
      frag.append(row);
    });
  });
  list.replaceChildren(frag);
  const ocN = rates.filter(r => r.type === 'overclock').length;
  const baseN = rates.filter(r => r.base === 1).length;
  $('rm-rates-caption').textContent = `${rates.length} 档 · 超频 ${ocN} · 基准 ${baseN}${rmDirty ? ' · 待保存' : ''}`;
  $('rm-rates-save').hidden = !rmDirty;
}

async function rmRatesSave() {
  if (!rmDirty || !rmEdit) return;
  const raw = rmEdit.map(r => `${r.id}:${r.w}:${r.h}:${r.fps}:${r.type}:${r.base}:${r.ord || 0}`).join(';');
  rmDirty = false;
  const saved = rmEdit;
  rmEdit = null;
  try {
    const result = await command(`ratectl rates "${raw}"`, 30000);
    if (result.rm) rm = result.rm;
    rmDraw();
    rmNotify('档位标注已保存并即时生效。');
  } catch (error) {
    rmDirty = true;
    rmEdit = saved;
    rmDraw();
    rmNotify(error.message, true);
  }
}

$('rm-entry').addEventListener('click', () => {
  $('rm-page').hidden = false;
  document.body.classList.add('rm-open');
  rmNotify('');
  if (rm) rmDraw();
  rmLoad();
});
$('rm-back').addEventListener('click', () => {
  $('rm-page').hidden = true;
  document.body.classList.remove('rm-open');
  refresh(false);
});
$('rm-scan').addEventListener('click', rmScan);
$('rm-unlock').addEventListener('click', () => rmAction('global id=0', '已解除全局锁定。'));
$('rm-stop').addEventListener('click', () => rmAction('stop', '已停止刷新率管理服务, 交还系统自动调频。'));
$('rm-appsw').addEventListener('change', () => {
  rmAction(`appsw appsw=${$('rm-appsw').checked ? 1 : 0}`,
    $('rm-appsw').checked ? '按应用自动切换已开启。' : '按应用自动切换已关闭。');
});
let rmIntvTimer = 0;
$('rm-intv').addEventListener('input', () => { $('rm-intv-v').textContent = $('rm-intv').value; });
$('rm-intv').addEventListener('change', () => {
  clearTimeout(rmIntvTimer);
  rmIntvTimer = setTimeout(() => {
    rmAction(`appsw appintv=${Number($('rm-intv').value) || 1}`, `检测间隔已设为 ${$('rm-intv').value} 秒。`);
  }, 250);
});
$('rm-rates-save').addEventListener('click', rmRatesSave);

// ---- 应用选择器 (供按应用添加) ----
let apTimer = 0;
async function openAppPicker() {
  if (apBusy) return;
  apBusy = true;
  const picker = $('app-picker');
  const list = $('ap-list');
  list.replaceChildren(span('app-empty', '正在读取应用列表…'));
  picker.hidden = false;
  $('ap-search').value = '';
  try {
    const result = await command('apps', 60000);
    const all = (Array.isArray(result.apps) ? result.apps : [])
      .map(a => (typeof a === 'string' ? { p: a, n: a } : a))
      .filter(a => a && a.p);
    all.forEach(a => { appNames[a.p] = a.n || a.p; });
    const appMap = rm?.apps && typeof rm.apps === 'object' ? rm.apps : {};
    const avail = all.filter(a => !(a.p in appMap));
    renderApList(avail, '');
    $('ap-search').oninput = () => {
      clearTimeout(apTimer);
      apTimer = setTimeout(() => renderApList(avail, $('ap-search').value.trim().toLowerCase()), 120);
    };
  } catch (error) {
    list.replaceChildren(span('app-empty', error.message));
  } finally {
    apBusy = false;
  }
}
function renderApList(avail, kw) {
  const list = $('ap-list');
  const items = kw ? avail.filter(a =>
    a.p.toLowerCase().includes(kw) || (a.n || '').toLowerCase().includes(kw)) : avail;
  const frag = document.createDocumentFragment();
  const rates = (rm?.rates || []).slice().sort((a, b) => b.fps - a.fps);
  const defId = rates.length ? rates[0].id : 0;
  const defFps = rates.length ? rates[0].fps : 0;
  items.slice(0, 300).forEach(a => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'ap-item';
    const name = span('ap-name', a.n || a.p);
    const pkg = span('ap-pkg', a.p);
    btn.append(name, pkg);
    btn.addEventListener('click', () => {
      $('app-picker').hidden = true;
      rmAction(`app set ${a.p} ${defId}`, `已添加 ${a.n || a.p} -> ${defFps}Hz, 可在名单中调整。`);
    });
    frag.append(btn);
  });
  if (!items.length) frag.append(span('app-empty', kw ? '无匹配的应用。' : '没有更多可添加的应用。'));
  list.replaceChildren(frag);
}
$('rm-app-add').addEventListener('click', openAppPicker);
$('ap-close').addEventListener('click', () => { $('app-picker').hidden = true; });
$('app-picker').addEventListener('click', event => {
  if (event.target === $('app-picker')) $('app-picker').hidden = true;
});

// ================= 充电相关子页面 (独立开关 · 全自定义参数) =================
let chg = null;       // 编辑状态 {limit,uncap,voff,mod,full_on,full,voffDts,fullDts,capable}
let chgBusy = false;
let chgDirty = false;

function chgNotify(message, isError = false) {
  const box = $('chg-notice');
  box.classList.toggle('error', !!isError);
  box.classList.toggle('notice', !isError);
  box.textContent = message || '';
  box.hidden = !message;
}

function chgLoad(b) {
  const nb = b || {};
  const fullDts = Number(nb.full_dts) || 0;
  const clamp = (v, lo, hi, dft) => (Number.isFinite(v) && v >= lo && v <= hi ? v : dft);
  chg = {
    limit: Number(nb.limit) ? 1 : 0,
    uncap: Number(nb.uncap) ? 1 : 0,
    voff: clamp(Number(nb.voff), 2700, 3350, 3000),
    mod: Number(nb.mod) ? 1 : 0,
    full_on: Number(nb.full_on) ? 1 : 0,
    full: clamp(Number(nb.full), 4300, 4570, 0),
    voffDts: Number(nb.voff_dts) || 0,
    fullDts,
    capable: !!state?.batt_capable,
  };
  if (!chg.full) chg.full = fullDts >= 4300 && fullDts <= 4570 ? fullDts : 4400;
  chgDirty = false;
  chgDraw();
}

function chgDraw() {
  if (!chg) return;
  const koMode = state?.oc_mode === 'ko';
  const dis = chgBusy || !connected;
  const lic = state?.license?.state === 'ok';
  const anyOn = chg.limit || chg.uncap || chg.mod || chg.full_on;
  ['chg-limit', 'chg-uncap', 'chg-mod', 'chg-fullsw', 'chg-voff', 'chg-full', 'chg-off'].forEach(id => { $(id).disabled = dis; });
  $('chg-limit').checked = !!chg.limit;
  $('chg-uncap').checked = !!chg.uncap;
  $('chg-mod').checked = !!chg.mod;
  $('chg-fullsw').checked = !!chg.full_on;
  $('chg-mod-row').hidden = !chg.capable;
  $('chg-voff-box').hidden = !chg.uncap;
  $('chg-full-box').hidden = !chg.full_on;
  $('chg-voff').value = String(chg.voff);
  $('chg-voff-v').textContent = String(chg.voff);
  $('chg-voff-p1').textContent = String(chg.voff + 50);
  $('chg-full').value = String(chg.full);
  $('chg-full-v').textContent = String(chg.full);
  $('chg-full-dts').textContent = chg.fullDts ? String(chg.fullDts) : '未识别';
  const on = [];
  if (chg.limit) on.push('解除限流');
  if (chg.uncap) on.push(`解容 ${chg.voff}mV`);
  if (chg.mod) on.push('魔改 6100mAh');
  if (chg.full_on) on.push(`满充 ${chg.full}mV`);
  const capText = on.length ? on.join(' · ') : '全部关闭';
  $('chg-sw-caption').textContent = chgDirty ? `${capText} · 待保存` : capText;
  $('chg-entry-cap').textContent = koMode ? 'KO 挂载方式下不可用' : capText;
  $('chg-sub').textContent = koMode
    ? '当前为 KO 挂载方式, 充电相关功能不可用'
    : `基准关机 ${chg.voffDts ? `${chg.voffDts}mV` : '未识别'} · 基准满充 ${chg.fullDts ? `${chg.fullDts}mV` : '未识别'}`;
  $('chg-save').disabled = dis || koMode;
  $('chg-save-label').textContent = chgBusy ? '正在处理…' : (!lic && anyOn ? '需先完成QQ群验证' : '保存并应用');
}

function chgMark() {
  chgDirty = true;
  chgDraw();
}

async function chgSave() {
  if (chgBusy || !chg || !state) return;
  if (state.oc_mode === 'ko') {
    chgNotify('当前为 KO 挂载方式, 不修改 DTBO, 充电相关功能不可用。', true);
    return;
  }
  const anyOn = chg.limit || chg.uncap || chg.mod || chg.full_on;
  if (anyOn && state.license?.state !== 'ok') {
    chgNotify('请先在主页完成QQ群验证, 再开启充电相关功能。', true);
    return;
  }
  chgBusy = true;
  chgDraw();
  chgNotify('正在保存充电相关配置并应用… (包含解包/打包/刷入, 请稍候)');
  try {
    await command(`save batt_limit=${chg.limit} batt_uncap=${chg.uncap} batt_voff=${chg.voff} batt_mod=${chg.mod} batt_full_on=${chg.full_on} batt_full=${chg.full_on ? chg.full : 0}`);
    const result = await command('apply', 120000);
    chgDirty = false;
    chgNotify(result.message || '已应用, 重启后生效。');
    render(await command('status'));
  } catch (error) {
    chgNotify(error.message, true);
    try { render(await command('status')); } catch { connected = false; }
  } finally {
    chgBusy = false;
    chgDraw();
  }
}

$('chg-limit').addEventListener('change', () => { chg.limit = $('chg-limit').checked ? 1 : 0; chgMark(); });
$('chg-uncap').addEventListener('change', () => { chg.uncap = $('chg-uncap').checked ? 1 : 0; chgMark(); });
$('chg-mod').addEventListener('change', () => { chg.mod = $('chg-mod').checked ? 1 : 0; chgMark(); });
$('chg-fullsw').addEventListener('change', () => { chg.full_on = $('chg-fullsw').checked ? 1 : 0; chgMark(); });
$('chg-voff').addEventListener('input', () => {
  chg.voff = Number($('chg-voff').value) || 3000;
  $('chg-voff-v').textContent = String(chg.voff);
  $('chg-voff-p1').textContent = String(chg.voff + 50);
});
$('chg-voff').addEventListener('change', chgMark);
$('chg-full').addEventListener('input', () => {
  chg.full = Number($('chg-full').value) || 4400;
  $('chg-full-v').textContent = String(chg.full);
});
$('chg-full').addEventListener('change', chgMark);
$('chg-off').addEventListener('click', () => {
  if (!chg) return;
  chg.limit = 0; chg.uncap = 0; chg.mod = 0; chg.full_on = 0;
  chgMark();
  chgNotify('已全部关闭 (尚未保存, 请点击「保存并应用」)。');
});
$('chg-entry').addEventListener('click', () => {
  $('chg-page').hidden = false;
  document.body.classList.add('rm-open');
  chgNotify('');
  chgDraw();
});
$('chg-back').addEventListener('click', () => {
  $('chg-page').hidden = true;
  document.body.classList.remove('rm-open');
  refresh(false);
});
$('chg-save').addEventListener('click', chgSave);

// ================= 主题 =================
const THEME_KEY = 'dtbo_theme';
let theme = {};
try { theme = JSON.parse(localStorage.getItem(THEME_KEY)) || {}; } catch { theme = {}; }
function saveTheme() {
  try { localStorage.setItem(THEME_KEY, JSON.stringify(theme)); } catch { }
}
let dominantColor = '';
const modeQuery = window.matchMedia ? matchMedia('(prefers-color-scheme: dark)') : null;
function resolvedMode() {
  const pref = theme.mode || 'auto';
  if (pref === 'auto') return modeQuery && modeQuery.matches ? 'dark' : 'light';
  return pref;
}
function applyTheme() {
  const root = document.documentElement.style;
  const glass = !!theme.glass;
  root.setProperty('--bg-show', theme.bgShow ?? 0.35);
  root.setProperty('--card-alpha', theme.cardAlpha ?? 1);
  root.setProperty('--ctl-alpha', theme.ctlAlpha ?? 1);
  document.documentElement.dataset.mode = resolvedMode();
  document.documentElement.dataset.accent = theme.accent || 'green';
  $('bg-layer').style.backgroundImage = theme.img ? `url(${theme.img})` : '';
  document.body.classList.toggle('glass', glass);
  document.body.classList.toggle('hoverfx', theme.hover !== false);
  $('bg-show').value = theme.bgShow ?? 0.35;
  $('card-alpha').value = theme.cardAlpha ?? 1;
  $('ctl-alpha').value = theme.ctlAlpha ?? 1;
  $('glass-toggle').checked = glass;
  $('hover-toggle').checked = theme.hover !== false;
  const pref = theme.mode || 'auto';
  document.querySelectorAll('#mode-seg .mini-btn').forEach(b => b.classList.toggle('on', b.dataset.mode === pref));
  const accent = theme.accent || 'green';
  document.querySelectorAll('#accent-row .swatch').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.accent === accent)));
  updateStatusBar();
}
let themeRaf = 0;
function scheduleTheme() {
  if (themeRaf) return;
  themeRaf = requestAnimationFrame(() => { themeRaf = 0; applyTheme(); });
}
function updateStatusBar() {
  let color = getComputedStyle(document.documentElement).getPropertyValue('--sb').trim() || '#0c1310';
  if (theme.img) {
    if (dominantColor) color = dominantColor;
    else { extractDominant(); return; }
  }
  const meta = document.querySelector('meta[name=theme-color]');
  if (meta) meta.setAttribute('content', color);
  document.documentElement.style.backgroundColor = color;
}
function extractDominant() {
  const img = new Image();
  img.onload = () => {
    try {
      const c = document.createElement('canvas');
      c.width = 8; c.height = 8;
      const ctx = c.getContext('2d');
      ctx.drawImage(img, 0, 0, 8, 8);
      const d = ctx.getImageData(0, 0, 8, 8).data;
      let r = 0, g = 0, b = 0, n = 0;
      for (let i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; n++; }
      dominantColor = '#' + [r, g, b].map(v => Math.round(v / n * 0.6).toString(16).padStart(2, '0')).join('');
    } catch { dominantColor = ''; }
    updateStatusBar();
  };
  img.src = theme.img;
}
const panel = $('theme-panel');
let panelTimer = 0;
function panelOpen(open) {
  clearTimeout(panelTimer);
  if (open) {
    panel.hidden = false;
    panel.offsetHeight;
    panel.classList.add('open');
  } else {
    panel.classList.remove('open');
    panelTimer = setTimeout(() => { panel.hidden = true; }, 170);
  }
}
$('theme-btn').addEventListener('click', event => {
  event.stopPropagation();
  panelOpen(panel.hidden || !panel.classList.contains('open'));
});
$('theme-panel').addEventListener('click', event => event.stopPropagation());
document.addEventListener('click', event => {
  if (!event.target.closest('#theme-panel')) panelOpen(false);
});
$('mode-seg').addEventListener('click', event => {
  const b = event.target.closest('button[data-mode]');
  if (!b) return;
  theme.mode = b.dataset.mode;
  saveTheme();
  applyTheme();
});
$('accent-row').addEventListener('click', event => {
  const b = event.target.closest('button[data-accent]');
  if (!b) return;
  theme.accent = b.dataset.accent;
  saveTheme();
  applyTheme();
});
if (modeQuery) {
  const onSchemeChange = () => { if ((theme.mode || 'auto') === 'auto') applyTheme(); };
  if (modeQuery.addEventListener) modeQuery.addEventListener('change', onSchemeChange);
  else if (modeQuery.addListener) modeQuery.addListener(onSchemeChange);
}
$('bg-pick').addEventListener('click', () => $('bg-file').click());
$('bg-clear').addEventListener('click', () => {
  delete theme.img;
  dominantColor = '';
  saveTheme();
  applyTheme();
});
$('bg-file').addEventListener('change', () => {
  const file = $('bg-file').files[0];
  $('bg-file').value = '';
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, 1080 / Math.max(image.width, image.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(image.width * scale);
      canvas.height = Math.round(image.height * scale);
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      theme.img = canvas.toDataURL('image/jpeg', 0.82);
      dominantColor = '';
      saveTheme();
      applyTheme();
    };
    image.src = reader.result;
  };
  reader.readAsDataURL(file);
});
const bindSlider = (id, key) => {
  $(id).addEventListener('input', () => { theme[key] = Number($(id).value); scheduleTheme(); });
  $(id).addEventListener('change', saveTheme);
};
bindSlider('bg-show', 'bgShow');
bindSlider('card-alpha', 'cardAlpha');
bindSlider('ctl-alpha', 'ctlAlpha');
$('glass-toggle').addEventListener('change', () => { theme.glass = $('glass-toggle').checked; saveTheme(); applyTheme(); });
$('hover-toggle').addEventListener('change', () => { theme.hover = $('hover-toggle').checked; saveTheme(); applyTheme(); });
applyTheme();

$('copy-machine').addEventListener('click', async () => {
  const id = state?.machine || $('machine-id').textContent;
  if (!id || id === '—') return;
  try {
    await navigator.clipboard.writeText(id);
    notify(`已复制主板ID: ${id}`);
  } catch {
    const input = document.createElement('textarea');
    input.value = id;
    document.body.append(input);
    input.select();
    document.execCommand('copy');
    input.remove();
    notify(`已复制主板ID: ${id}`);
  }
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && $('rm-page').hidden && $('chg-page').hidden) refresh(false);
});
refresh(false);
