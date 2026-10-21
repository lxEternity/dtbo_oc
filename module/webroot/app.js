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
let sel = { hz: null, battery: null, oc_mode: null, ltpo_off: null };

const BATT_LABELS = {
  0: ['原版电池', '保持出厂电池与充电策略'],
  1: ['解除充电限流', '电池参数保持原版'],
  2: ['解除限流 + 电池解容', '关机 2.8V / 1% 2.85V / 显示真实电量'],
  3: ['6100mAh 魔改电池', '关机 3.0V / 1% 3.05V / 满充 4.54V'],
  4: ['魔改电池 + 解除限流', '同 6100mAh 并解除充电限流'],
  5: ['原版电池 + 电池解容', '关机 2.8V / 1% 2.85V / 显示真实电量'],
  6: ['GT7P 竞速版解容', '满充 4.55V / 关机 2.85V / 显示真实电量']
};

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

function licBlocked() {
  const licOk = state?.license?.state === 'ok';
  const needOC = (sel.hz ?? 0) > 0 || (sel.oc_mode === 'dtbo' && (sel.battery ?? 0) > 0);
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

function drawBatts() {
  const options = [0, 1, 2, 5];
  if (state?.batt_capable) options.push(3, 4);
  if (state?.device === 'gt7p') options.length = 0, options.push(0, 6);
  const fragment = document.createDocumentFragment();
  options.forEach(v => {
    const [title, detail] = BATT_LABELS[v] || [`选项 ${v}`, ''];
    const checked = sel.battery === v;
    const button = radioButton('batt-choice', title, checked, () => {
      sel.battery = v; dirty = true; drawBatts(); controls();
    });
    const t = span('b-title', title);
    if (v === 3 || v === 4) t.classList.add('warn');
    button.append(t, span('b-detail', detail));
    fragment.append(button);
  });
  $('batts').replaceChildren(fragment);
  $('batt-caption').textContent = `${options.length} 个方案`;
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
      if (sel.battery !== 0) sel.battery = 0;
      drawModes(); drawBatts(); controls();
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
  sel = { hz: data.hz, battery: data.battery, oc_mode: data.oc_mode, ltpo_off: data.ltpo_off };
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
  drawBatts();
  drawModes();
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
    if (sel.oc_mode === 'ko' && sel.battery !== 0) sel.battery = 0;
    await command(`save hz=${sel.hz} battery=${sel.battery} oc_mode=${sel.oc_mode} ltpo_off=${sel.ltpo_off ? 1 : 0}`);
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

['rates', 'batts', 'modes'].forEach(id => $(id).addEventListener('keydown', event => {
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

// ================= 充电控制 (模拟恒压, 无联网验证) =================
let chg = null;
let chgBusy = false;
let chgDirty = false;
let chgTimer = 0;
let chgSlidersBuilt = false;
const chgCtl = {};

const CHG_SLIDERS = [
  { k: 'cv_vol_mv', label: '恒压电压', hint: '进入恒压阶段的目标电压', min: 4400, max: 4620, step: 5, unit: 'mV' },
  { k: 'cv_max_ma', label: '恒压阶段电流', hint: '恒压阶段允许的最大充电电流', min: 200, max: 13700, step: 100, unit: 'mA' },
  { k: 'batt_full_thr_mv', label: '充满电压', hint: '区分纯碳 (4470) 与硅碳 (4570), 不了解勿改', min: 4400, max: 4570, step: 10, unit: 'mV' },
  { k: 'fast_max', label: 'UFCS/SVOOC 最大电流', hint: '单电芯最高 10900mA, 双电芯最高 13700mA', min: 1000, max: 13700, step: 100, unit: 'mA' },
  { k: 'pps_max', label: 'PPS 最大电流', min: 1000, max: 8500, step: 100, unit: 'mA' },
  { k: 'tc_vol_thr_mv', label: '涓流切换电压', min: 4300, max: 4560, step: 5, unit: 'mV' },
  { k: 'tc_thr_soc', label: '涓流切换电量', min: 50, max: 100, step: 1, unit: '%' },
  { k: 'tc_vol_full_mv', label: '涓流充满电压', min: 4300, max: 4560, step: 5, unit: 'mV' },
  { k: 'tc_full_ma', label: '涓流电流', min: 100, max: 2000, step: 50, unit: 'mA' },
  { k: 'max_ufcs_chg_reset_cc', label: '充电器重置次数', hint: '异常时重协商充电器 (0=关闭, 150W 头 ≤2)', min: 0, max: 10, step: 1, unit: '次' },
  { k: 'ufcs_reset_delay', label: '重置最短间隔', hint: '低于此间隔不进行复位', min: 0, max: 300, step: 10, unit: '秒' },
  { k: 'comfort_temp_decic', label: '舒适温控上限', min: 350, max: 450, step: 1, unit: '°C', decic: true },
  { k: 'batt_temp_high_decic', label: '极限温度上限', hint: '最高 55.0°C, 请注意散热', min: 350, max: 550, step: 1, unit: '°C', decic: true },
  { k: 'night_start_min', label: '夜间开始时间', min: 0, max: 1439, step: 15, unit: '', time: true },
  { k: 'night_end_min', label: '夜间结束时间', min: 0, max: 1439, step: 15, unit: '', time: true },
];
const CHG_SWITCHES = [
  ['chg-enabled', 'enabled'], ['chg-ufcs', 'ufcs'], ['chg-pps', 'pps'], ['chg-svooc', 'svooc'],
  ['chg-plc', 'ignore_plc'], ['chg-faket', 'faket'], ['chg-glide', 'thermal_glide_cap'], ['chg-night', 'night_comfort'],
];
const CHG_KEYS = ['enabled', 'ufcs', 'pps', 'svooc', 'faket', 'ignore_plc', 'curr_convergence',
  'fast_max', 'pps_max', 'cable_override', 'max_ufcs_chg_reset_cc', 'ufcs_reset_delay',
  'cv_vol_mv', 'cv_max_ma', 'batt_full_thr_mv', 'tc_vol_thr_mv', 'tc_thr_soc', 'tc_full_ma', 'tc_vol_full_mv',
  'thermal_mode', 'comfort_temp_decic', 'batt_temp_high_decic', 'thermal_glide_cap',
  'night_comfort', 'night_start_min', 'night_end_min'];

function chgNotify(message, isError = false) {
  const box = $('chg-notice');
  box.classList.toggle('err', !!isError);
  box.textContent = message;
  box.hidden = !message;
}

function chgBuildSliders() {
  if (chgSlidersBuilt) return;
  const wrap = $('chg-params');
  const frag = document.createDocumentFragment();
  CHG_SLIDERS.forEach(s => {
    const row = document.createElement('div');
    row.className = 'chg-row';
    const head = document.createElement('div');
    head.className = 'chg-row-head';
    head.append(span('', s.label));
    if (s.hint) {
      const h = document.createElement('small');
      h.textContent = s.hint;
      head.append(h);
    }
    const toDisp = s.decic ? v => (v / 10).toFixed(1)
      : s.time ? v => `${String(Math.floor(v / 60)).padStart(2, '0')}:${String(v % 60).padStart(2, '0')}`
        : v => String(v);
    const toRaw = s.decic ? d => Math.round(parseFloat(d) * 10)
      : s.time ? d => {
        const m = /^(\d{1,2}):(\d{1,2})$/.exec(String(d).trim());
        return m ? Math.min(1439, (+m[1]) * 60 + (+m[2])) : NaN;
      }
        : d => parseInt(d, 10);
    const range = document.createElement('input');
    range.type = 'range';
    const field = document.createElement('input');
    if (s.time) {
      range.min = s.min; range.max = s.max; range.step = s.step;
      field.type = 'text'; field.inputMode = 'numeric'; field.placeholder = 'HH:MM';
    } else if (s.decic) {
      range.min = s.min / 10; range.max = s.max / 10; range.step = 0.1;
      field.type = 'number'; field.min = s.min / 10; field.max = s.max / 10; field.step = 0.1; field.inputMode = 'decimal';
    } else {
      range.min = s.min; range.max = s.max; range.step = s.step;
      field.type = 'number'; field.min = s.min; field.max = s.max; field.step = s.step; field.inputMode = 'numeric';
    }
    range.setAttribute('aria-label', s.label);
    field.setAttribute('aria-label', s.label);
    const apply = raw => {
      if (!Number.isFinite(raw)) return;
      raw = Math.max(s.min, Math.min(s.max, Math.round(raw)));
      chgSet(s.k, raw);
      range.value = s.decic ? (raw / 10) : String(raw);
      field.value = toDisp(raw);
    };
    range.addEventListener('input', () => apply(toRaw(range.value)));
    field.addEventListener('change', () => apply(toRaw(field.value)));
    const ctl = document.createElement('div');
    ctl.className = 'chg-row-ctl';
    ctl.append(range, field);
    if (s.unit) ctl.append(span('chg-unit', s.unit));
    row.append(head, ctl);
    frag.append(row);
    chgCtl[s.k] = { range, field, toDisp };
  });
  wrap.replaceChildren(frag);
  chgSlidersBuilt = true;
}

function chgSet(k, v) {
  if (!chg) return;
  chg[k] = v;
  chgDirty = true;
  $('chg-save').disabled = false;
}

function chgDraw() {
  chgBuildSliders();
  const c = chg || {};
  const supported = c.support !== 0;
  document.querySelectorAll('#chg-page .rm-section').forEach(sec => {
    if (sec.id === 'chg-unsupported' || sec.id === 'chg-live-section') return;
    sec.hidden = !supported;
  });
  CHG_SWITCHES.forEach(([id, k]) => { $(id).checked = c[k] === 1; });
  document.querySelectorAll('.chg-mode-seg .rc-seg').forEach(b =>
    b.classList.toggle('on', b.dataset.mode === (c.thermal_mode || 'comfort')));
  if (!chgDirty) {
    CHG_SLIDERS.forEach(s => {
      const ctl = chgCtl[s.k];
      const v = c[s.k];
      if (!ctl || v === undefined || v === null) return;
      ctl.range.value = s.decic ? (v / 10) : String(v);
      ctl.field.value = ctl.toDisp(v);
    });
  }
}

const CHG_STAGES = { off: '已关闭 (官方曲线)', idle: '未充电', boot: '协商跟随中', chg: '快充', cv: '恒压', tail: '涓流' };

function chgDrawLive() {
  const c = chg || {};
  $('chg-vbat').textContent = c.vbat != null ? c.vbat : '—';
  $('chg-ichg').textContent = c.ichg != null ? c.ichg : '—';
  $('chg-temp').textContent = c.temp != null ? (c.temp / 10).toFixed(1) : '—';
  $('chg-soc').textContent = c.soc != null ? c.soc : '—';
  let st = CHG_STAGES[c.stage] || c.stage || '—';
  if (typeof c.stage === 'string' && c.stage.includes('/')) {
    st = `${CHG_STAGES[c.stage.split('/')[0]] || c.stage} · 温控降额`;
  }
  $('chg-stage').textContent = st;
  $('chg-target').textContent = c.fv && c.fcc ? `FV ${c.fv}mV · FCC ${c.fcc}mA` : '—';
  const running = c.daemon === 1;
  $('chg-live-cap').textContent = running ? '服务运行中' : '服务已停止';
  $('chg-sub').textContent = `${running ? '服务运行中' : '服务已停止'} · 恒压${c.enabled === 1 ? '开启' : '关闭'}${c.status ? ` · ${c.status}` : ''}`;
  $('chg-stop').textContent = running ? '停止服务' : '启动服务';
  $('chg-entry-cap').textContent = c.support === 0 ? '本机不支持 (无 votable 接口)'
    : `${running ? '运行中' : '已停止'} · 恒压${c.enabled === 1 ? '开启' : '关闭'}`;
}

async function chgAction(args, okMsg, timeoutMs = 30000) {
  if (chgBusy) return;
  chgBusy = true;
  try {
    const result = await command(`chg ${args}`, timeoutMs);
    if (result.chg) {
      chg = result.chg;
      if (!chgDirty) chgDraw();
      chgDrawLive();
    }
    if (okMsg || result.message) chgNotify(okMsg || result.message);
  } catch (error) {
    chgNotify(error.message, true);
  } finally {
    chgBusy = false;
  }
}

async function chgPoll() {
  if (chgBusy || $('chg-page').hidden) return;
  try {
    const result = await command('chg status', 15000);
    if (!result.chg) return;
    if (!chgDirty) {
      chg = result.chg;
      chgDraw();
    } else {
      const live = {};
      ['daemon', 'support', 'stage', 'status', 'error', 'vbat', 'ichg', 'temp', 'soc', 'ts', 'fv', 'fcc', 'state_ts']
        .forEach(k => { if (result.chg[k] !== undefined) live[k] = result.chg[k]; });
      chg = { ...chg, ...live };
    }
    chgDrawLive();
  } catch { /* 静默轮询 */ }
}

async function chgSave() {
  if (!chgDirty || !chg || chgBusy) return;
  chgBusy = true;
  $('chg-save').disabled = true;
  const args = CHG_KEYS.filter(k => chg[k] !== undefined && chg[k] !== null).map(k => `${k}=${chg[k]}`).join(' ');
  try {
    const result = await command(`chg save ${args}`, 30000);
    chgDirty = false;
    if (result.chg) { chg = result.chg; chgDraw(); chgDrawLive(); }
    chgNotify(result.message || '配置已保存并应用。');
  } catch (error) {
    chgDirty = true;
    $('chg-save').disabled = false;
    chgNotify(error.message, true);
  } finally {
    chgBusy = false;
  }
}

CHG_SWITCHES.forEach(([id, k]) => {
  $(id).addEventListener('change', () => chgSet(k, $(id).checked ? 1 : 0));
});
document.querySelector('.chg-mode-seg').addEventListener('click', event => {
  const b = event.target.closest('button[data-mode]');
  if (!b) return;
  chgSet('thermal_mode', b.dataset.mode);
  document.querySelectorAll('.chg-mode-seg .rc-seg').forEach(x => x.classList.toggle('on', x === b));
});
$('chg-save').addEventListener('click', chgSave);
$('chg-stop').addEventListener('click', () => {
  if (chg?.daemon === 1) chgAction('stop', '恒压服务已停止, 已交还官方充电策略。');
  else chgAction('start', '恒压服务已启动。');
});
let chgResetArmed = 0;
$('chg-reset').addEventListener('click', () => {
  const now = Date.now();
  if (now - chgResetArmed > 3000) {
    chgResetArmed = now;
    $('chg-reset').textContent = '再次点击确认';
    setTimeout(() => { chgResetArmed = 0; $('chg-reset').textContent = '恢复默认'; }, 3000);
    return;
  }
  chgResetArmed = 0;
  $('chg-reset').textContent = '恢复默认';
  chgDirty = false;
  $('chg-save').disabled = true;
  chgAction('reset', '已恢复默认配置。');
});
$('chg-log').addEventListener('click', async () => {
  try {
    const result = await command('chg log', 15000);
    const view = $('chg-logview');
    view.textContent = result.log || '(暂无日志)';
    view.hidden = false;
  } catch (error) {
    chgNotify(error.message, true);
  }
});
$('chg-entry').addEventListener('click', () => {
  $('chg-page').hidden = false;
  document.body.classList.add('rm-open');
  chgNotify('');
  chgAction('status', '');
  if (!chgTimer) chgTimer = setInterval(chgPoll, 3000);
});
$('chg-back').addEventListener('click', () => {
  $('chg-page').hidden = true;
  document.body.classList.remove('rm-open');
  if (chgTimer) { clearInterval(chgTimer); chgTimer = 0; }
  refresh(false);
});

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
  if (!document.hidden && $('rm-page').hidden) refresh(false);
});
refresh(false);
