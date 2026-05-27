/* ============================================================
   HeaderFilter — 通用表頭點擊式篩選/排序元件
   接 brief「採購頁 UI 改造」(PR#16 後續)
   ----------------------------------------------------------
   使用:
     const hf = HeaderFilter.init({
       thead: document.getElementById('xxx-thead'),
       columns: [
         { key:'product_code', label:'品號', type:'plain' },
         { key:'status',       label:'狀態', type:'filter',
           getValues: r => [r.stock_alert_level, r.stockless_alert_level].filter(Boolean),
           options: [
             { value:'🔴 嚴重缺貨', group:'缺貨類' },
             { value:'🟠 即將缺貨', group:'缺貨類' },
             ...
           ],
         },
         { key:'recent_3m_avg', label:'近3月銷', type:'sort', num:true },
       ],
       onChange: () => renderTable(),
     });
   API:
     hf.render()                重繪 thead
     hf.applyTo(rows)           回傳過濾排序後的 rows
     hf.getChips()              回傳 [{key,label,clear()}] 給「已套用」chip 區
     hf.clearAll()              清掉所有 filter + sort
     hf.state.filters / .sort   讀寫狀態(內部維護)
   ============================================================ */
window.HeaderFilter = (function () {
  const _instances = [];
  let _activePopover = null;

  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    }[c]));
  }

  function init(opts) {
    const inst = {
      thead: opts.thead,
      columns: opts.columns,
      state: { filters: {}, sort: null },
      onChange: opts.onChange || function () {},
      _allRows: [],
    };
    inst.render = () => renderHead(inst);
    inst.applyTo = (rows) => {
      inst._allRows = rows;          // auto-options 時用
      return applyFilterSort(inst, rows);
    };
    inst.getChips = () => buildChips(inst);
    inst.clearAll = () => {
      inst.state.filters = {}; inst.state.sort = null;
      inst.render(); inst.onChange();
    };
    inst.clearFilter = (key) => {
      delete inst.state.filters[key];
      inst.render(); inst.onChange();
    };
    inst.render();
    _instances.push(inst);
    // 點 popover 外面關閉
    if (_instances.length === 1) {
      document.addEventListener('click', (e) => {
        if (!_activePopover) return;
        if (_activePopover.el.contains(e.target)) return;
        // 點到對應 th 也算外面(由 th 自己 handler 處理 toggle)
        closePopover();
      });
      window.addEventListener('resize', closePopover);
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePopover(); });
    }
    return inst;
  }

  function renderHead(inst) {
    inst.thead.innerHTML = '<tr>' + inst.columns.map((c, idx) => {
      if (c.type === 'plain') {
        return `<th class="${c.num ? 'hf-num' : ''}${c.thClass ? ' '+c.thClass : ''}">${escapeHtml(c.label)}</th>`;
      }
      const isFilter = c.type === 'filter';
      const isSort   = c.type === 'sort';
      const filterActive = isFilter && !!(inst.state.filters[c.key] && inst.state.filters[c.key].size);
      const sortActive   = isSort   && inst.state.sort && inst.state.sort.key === c.key;
      const active = filterActive || sortActive;
      const arrow = isSort
        ? (sortActive ? (inst.state.sort.dir === 'asc' ? '▲' : '▼') : '▾')
        : (filterActive ? '●' : '▾');
      const cls = 'hf-th'
        + (active ? ' hf-active' : '')
        + (c.num ? ' hf-num' : '')
        + (c.thClass ? ' ' + c.thClass : '');
      return `<th class="${cls}" data-hf-idx="${idx}" title="${escapeHtml(c.hint || (isSort ? '點切排序' : '點開篩選'))}">
        ${escapeHtml(c.label)}<span class="hf-arrow">${arrow}</span></th>`;
    }).join('') + '</tr>';
    // 綁 click(用 delegate,值用 data attr 避免 escape 坑)
    inst.thead.querySelectorAll('th.hf-th').forEach(th => {
      th.addEventListener('click', (e) => {
        e.stopPropagation();
        const idx = Number(th.dataset.hfIdx);
        const col = inst.columns[idx];
        if (!col) return;
        if (_activePopover && _activePopover.col === col && _activePopover.inst === inst) {
          closePopover();
          return;
        }
        openPopover(inst, col, th);
      });
    });
  }

  function openPopover(inst, col, anchor) {
    closePopover();
    const pop = document.createElement('div');
    pop.className = 'hf-popover';
    if (col.type === 'sort') {
      renderSortPopover(pop, inst, col);
    } else {
      renderFilterPopover(pop, inst, col);
    }
    document.body.appendChild(pop);
    positionPopover(pop, anchor);
    _activePopover = { el: pop, inst, col };
  }

  function renderSortPopover(pop, inst, col) {
    const cur = inst.state.sort && inst.state.sort.key === col.key ? inst.state.sort.dir : null;
    pop.innerHTML = `
      <div class="hf-pop-title">${escapeHtml(col.label)} · 排序</div>
      <div class="hf-pop-row${cur==='asc'?' hf-pop-row-cur':''}" data-dir="asc">↑ 低到高</div>
      <div class="hf-pop-row${cur==='desc'?' hf-pop-row-cur':''}" data-dir="desc">↓ 高到低</div>
      ${cur ? '<div class="hf-pop-row hf-pop-clear" data-dir="">✕ 取消排序</div>' : ''}
    `;
    pop.querySelectorAll('.hf-pop-row').forEach(el => {
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        const dir = el.dataset.dir;
        if (!dir) inst.state.sort = null;
        else      inst.state.sort = { key: col.key, dir };
        inst.render(); inst.onChange();
        closePopover();
      });
    });
  }

  function autoOptions(inst, col) {
    const set = new Set();
    (inst._allRows || []).forEach(r => {
      const vals = col.getValues ? col.getValues(r) : [r[col.key]];
      vals.forEach(v => { if (v != null && v !== '') set.add(String(v)); });
    });
    const arr = [...set].sort((a, b) => String(a).localeCompare(String(b), 'zh-Hant'))
      .map(v => ({ value: v, label: v, group: col.groupOf ? col.groupOf(v) : null }));
    // 若有 groupOf,依 group 排序(穩定排序保留組內字母序)
    if (col.groupOf) {
      const order = col.groupOrder || [];
      arr.sort((a, b) => {
        const ia = order.indexOf(a.group); const ib = order.indexOf(b.group);
        const ga = ia < 0 ? 99 : ia; const gb = ib < 0 ? 99 : ib;
        return ga - gb;
      });
    }
    return arr;
  }

  function renderFilterPopover(pop, inst, col) {
    const opts = (col.options && col.options.length) ? col.options : autoOptions(inst, col);
    const curSet = inst.state.filters[col.key] || new Set();
    // 分組
    const groups = {};
    const groupOrder = [];
    opts.forEach(o => {
      const g = o.group || '__none__';
      if (!groups[g]) { groups[g] = []; groupOrder.push(g); }
      groups[g].push(o);
    });
    let html = `<div class="hf-pop-title">${escapeHtml(col.label)} · 篩選</div>
      <div class="hf-pop-actions">
        <button class="hf-btn" data-act="all">全選</button>
        <button class="hf-btn" data-act="none">全清</button>
        <span style="flex:1"></span>
        <span class="hf-pop-count">已選 ${curSet.size}</span>
      </div>
      <div class="hf-pop-list">`;
    groupOrder.forEach(g => {
      if (g !== '__none__') html += `<div class="hf-pop-group">${escapeHtml(g)}</div>`;
      groups[g].forEach((o, i) => {
        const checked = curSet.has(String(o.value));
        const optKey = `${escapeHtml(g)}__${i}`;
        html += `<label class="hf-pop-item">
          <input type="checkbox" data-opt="${optKey}" ${checked ? 'checked' : ''}>
          ${escapeHtml(o.label || o.value)}
        </label>`;
      });
    });
    html += '</div>';
    pop.innerHTML = html;
    // 把 value 對應的 element 用 map 連起來(避免 escape 坑)
    const valByEl = new Map();
    pop.querySelectorAll('.hf-pop-item').forEach((label, i) => {
      // 重新對齊:從 opts 依序拿 value
    });
    // 重新對齊一次,確保 i 跟 opts 順序一致
    const flatOpts = [];
    groupOrder.forEach(g => groups[g].forEach(o => flatOpts.push(o)));
    pop.querySelectorAll('.hf-pop-list input[type=checkbox]').forEach((cb, i) => {
      const val = String(flatOpts[i].value);
      cb.addEventListener('change', () => {
        const set = inst.state.filters[col.key] = inst.state.filters[col.key] || new Set();
        if (cb.checked) set.add(val);
        else            set.delete(val);
        if (set.size === 0) delete inst.state.filters[col.key];
        // 更新 popover count + th 高亮
        const cn = pop.querySelector('.hf-pop-count');
        if (cn) cn.textContent = '已選 ' + (inst.state.filters[col.key] ? inst.state.filters[col.key].size : 0);
        inst.render(); inst.onChange();
      });
    });
    pop.querySelectorAll('.hf-btn').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (btn.dataset.act === 'all') {
          inst.state.filters[col.key] = new Set(flatOpts.map(o => String(o.value)));
        } else {
          delete inst.state.filters[col.key];
        }
        // 重繪 popover 反映勾選
        const anchor = inst.thead.querySelector(`th[data-hf-idx="${inst.columns.indexOf(col)}"]`);
        closePopover();
        openPopover(inst, col, anchor);
        inst.render(); inst.onChange();
      });
    });
  }

  function positionPopover(pop, anchor) {
    const r = anchor.getBoundingClientRect();
    pop.style.position = 'absolute';
    pop.style.top  = (r.bottom + window.scrollY + 2) + 'px';
    // 防超出右邊
    const w = pop.offsetWidth || 240;
    let left = r.left + window.scrollX;
    if (left + w > window.innerWidth - 8) left = Math.max(8, window.innerWidth - w - 8);
    pop.style.left = left + 'px';
  }

  function closePopover() {
    if (_activePopover) {
      _activePopover.el.remove();
      _activePopover = null;
    }
  }

  function applyFilterSort(inst, rows) {
    let out = rows || [];
    // 多欄篩選 AND;同欄多值 OR(checkbox 勾的之一)
    Object.keys(inst.state.filters).forEach(k => {
      const set = inst.state.filters[k];
      if (!set || set.size === 0) return;
      const col = inst.columns.find(c => c.key === k);
      if (!col) return;
      out = out.filter(r => {
        const vals = col.getValues ? col.getValues(r) : [r[col.key]];
        return (vals || []).some(v => v != null && set.has(String(v)));
      });
    });
    // 排序
    if (inst.state.sort) {
      const col = inst.columns.find(c => c.key === inst.state.sort.key);
      if (col) {
        const dir = inst.state.sort.dir === 'asc' ? 1 : -1;
        const num = col.num;
        out = out.slice().sort((a, b) => {
          const va = col.getValue ? col.getValue(a) : a[col.key];
          const vb = col.getValue ? col.getValue(b) : b[col.key];
          if (num) {
            const na = va != null && va !== '' && isFinite(Number(va));
            const nb = vb != null && vb !== '' && isFinite(Number(vb));
            // NULL 統一沉底(不論 asc/desc)
            if (!na && !nb) return 0;
            if (!na) return 1;
            if (!nb) return -1;
            return (Number(va) - Number(vb)) * dir;
          }
          return String(va || '').localeCompare(String(vb || '')) * dir;
        });
      }
    }
    return out;
  }

  function buildChips(inst) {
    const chips = [];
    Object.keys(inst.state.filters).forEach(k => {
      const set = inst.state.filters[k];
      if (!set || set.size === 0) return;
      const col = inst.columns.find(c => c.key === k);
      const valTxt = set.size <= 2 ? [...set].join(' / ') : `${[...set][0]} 等 ${set.size} 項`;
      chips.push({
        key: 'flt:' + k,
        label: `${col ? col.label : k}:${valTxt}`,
        clear: () => { delete inst.state.filters[k]; inst.render(); inst.onChange(); },
      });
    });
    if (inst.state.sort) {
      const col = inst.columns.find(c => c.key === inst.state.sort.key);
      chips.push({
        key: '__sort__',
        label: `↕ ${col ? col.label : ''} ${inst.state.sort.dir === 'asc' ? '↑' : '↓'}`,
        clear: () => { inst.state.sort = null; inst.render(); inst.onChange(); },
      });
    }
    return chips;
  }

  return { init, closePopover };
})();
