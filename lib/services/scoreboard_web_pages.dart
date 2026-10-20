// GENERATED từ web/control.html và web/overlay.html — trang chạy offline,
// không dùng CDN. Sửa nội dung HTML/JS ở đây nếu cần.

/// Trang điều khiển bảng tỉ số cho trọng tài (`GET /control`).
const String scoreboardControlPageHtml = r'''<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<link rel="icon" href="data:,">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#0E1726">
<title>Bảng điểm · VNVAR</title>
<style>
:root{--bg:#0E1726;--panel:#16223A;--panel2:#1D2B47;--line:#2A3A5C;--text:#F2F5FA;--muted:#9FB0CC;--ok:#2ECC71;--bad:#FF5A5F;--warn:#FFC107;--accent:#3D8BFD;--a:#1565C0;--b:#C62828}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;font-size:15px}
body{display:flex;flex-direction:column;min-height:100%;padding-bottom:env(safe-area-inset-bottom)}
button,input,select,textarea{font:inherit;color:inherit}
button{cursor:pointer;border:0;border-radius:12px;background:var(--panel2);padding:12px 14px;font-weight:700;touch-action:manipulation;user-select:none;-webkit-user-select:none}
button:active{filter:brightness(1.25)}
button.primary{background:var(--accent);color:#fff}
button.danger{background:#5A1F27;color:#FFD6D8}
button.ghost{background:transparent;border:1px solid var(--line)}
button[disabled]{opacity:.45;pointer-events:none}
header{display:flex;align-items:center;gap:10px;padding:10px 14px 6px;padding-top:max(10px,env(safe-area-inset-top))}
header .title{flex:1;min-width:0}
header .title b{display:block;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
header .title small{display:block;color:var(--muted);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.conn{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--muted);white-space:nowrap}
.conn i{width:10px;height:10px;border-radius:50%;background:var(--bad);box-shadow:0 0 0 3px rgba(255,90,95,.2)}
.conn.on i{background:var(--ok);box-shadow:0 0 0 3px rgba(46,204,113,.2)}
nav{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;padding:4px 10px 8px}
nav button{padding:10px 4px;font-size:13px;background:var(--panel);color:var(--muted)}
nav button.on{background:var(--accent);color:#fff}
main{flex:1;display:flex;flex-direction:column;padding:0 10px 12px;min-height:0}
section.tab{display:none;flex:1;flex-direction:column;gap:10px;min-height:0}
section.tab.on{display:flex}
section.tab>*{flex-shrink:0}
/* SCORE */
.board{flex:1;display:grid;grid-template-rows:1fr auto 1fr;gap:8px;min-height:360px}
.team{position:relative;border-radius:18px;padding:12px 14px;display:flex;flex-direction:column;justify-content:space-between;overflow:hidden;cursor:pointer;user-select:none;-webkit-user-select:none;touch-action:manipulation;min-height:150px}
.team::after{content:"";position:absolute;inset:0;background:linear-gradient(180deg,rgba(255,255,255,.08),rgba(0,0,0,.18));pointer-events:none}
.team.flash{animation:flash .35s ease}
@keyframes flash{0%{filter:brightness(1.6)}100%{filter:none}}
.team .row{display:flex;align-items:center;gap:8px;position:relative;z-index:1}
.team .name{font-size:20px;font-weight:800;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.team .players{font-size:12px;opacity:.85;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.serve{display:none;align-items:center;gap:4px;background:rgba(0,0,0,.35);border-radius:999px;padding:3px 9px;font-size:12px;font-weight:800;color:var(--warn)}
.serve.on{display:inline-flex}
.serve::before{content:"";width:9px;height:9px;border-radius:50%;background:var(--warn)}
.pts{font-size:min(30vw,150px);line-height:1;font-weight:900;text-align:center;font-variant-numeric:tabular-nums;position:relative;z-index:1;text-shadow:0 4px 18px rgba(0,0,0,.35)}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{background:rgba(0,0,0,.3);border-radius:8px;padding:2px 8px;font-size:12px;font-weight:700}
.minus{position:relative;z-index:2;background:rgba(0,0,0,.35);border-radius:10px;padding:8px 12px;font-size:13px;overflow:hidden}
.minus .fill{position:absolute;left:0;top:0;bottom:0;width:0;background:rgba(255,255,255,.35)}
.minus.holding .fill{animation:fill .6s linear forwards}
@keyframes fill{to{width:100%}}
.mid{display:flex;align-items:center;justify-content:space-between;gap:8px;background:var(--panel);border-radius:14px;padding:8px 12px}
.mid .set{font-weight:800}
.mid .callout{font-size:22px;font-weight:900;letter-spacing:1px;color:var(--warn);font-variant-numeric:tabular-nums}
.mid .hint{font-size:11px;color:var(--muted)}
.actions{display:grid;grid-template-columns:2fr 1fr 1fr;gap:8px}
.actions button{padding:16px 8px;font-size:15px}
.finished{background:#203a24;border:1px solid #2ECC71;border-radius:14px;padding:10px 12px;text-align:center;font-weight:800;display:none}
.finished.on{display:block}
@media (orientation:landscape) and (min-width:600px){
 .board{grid-template-columns:1fr auto 1fr;grid-template-rows:1fr}
 .mid{flex-direction:column;justify-content:center;min-width:120px;text-align:center}
}
@media (orientation:landscape) and (max-height:500px){
 .board{min-height:0;flex:1 1 0}
 .team{min-height:0;padding:8px 12px}
 .pts{font-size:min(24vw,22vh);font-size:min(24vw,30dvh)}
 .actions button{padding:10px 8px}
}
/* FORMS */
.card{background:var(--panel);border-radius:16px;padding:12px;display:flex;flex-direction:column;gap:10px}
.card h3{margin:0;font-size:15px;display:flex;align-items:center;gap:8px}
.card h3 .dot{width:12px;height:12px;border-radius:50%}
label.f{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--muted)}
label.f input,label.f select,label.f textarea{background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:11px 10px;color:var(--text);font-size:15px;width:100%}
label.f input[type=color]{padding:2px;height:44px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.check{display:flex;align-items:center;gap:10px;font-size:14px;padding:6px 2px}
.check input{width:22px;height:22px}
.logo-row{display:flex;align-items:center;gap:10px}
.logo-row img{width:52px;height:52px;object-fit:contain;background:var(--bg);border-radius:10px;border:1px solid var(--line)}
.seg{display:grid;gap:6px}
.seg button{padding:12px 6px;font-size:13px;background:var(--panel2)}
.seg button.on{background:var(--accent);color:#fff}
.preview{position:relative;width:100%;aspect-ratio:16/9;border-radius:12px;overflow:hidden;background:#333 repeating-conic-gradient(#3b3b3b 0 25%,#2b2b2b 0 50%) 0 0/24px 24px}
.preview iframe{position:absolute;left:0;top:0;width:1920px;height:1080px;border:0;transform-origin:0 0;pointer-events:none;background:transparent}
.timerv{font-size:34px;font-weight:900;text-align:center;font-variant-numeric:tabular-nums}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace;word-break:break-all;font-size:13px;background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:10px}
.muted{color:var(--muted);font-size:12px}
/* OVERLAYS */
.shade{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:flex-end;justify-content:center;z-index:50}
.shade.on{display:flex}
.sheet{background:var(--panel);width:100%;max-width:520px;border-radius:20px 20px 0 0;padding:16px 14px max(16px,env(safe-area-inset-bottom));display:flex;flex-direction:column;gap:8px}
.sheet h3{margin:0 0 4px;font-size:16px}
.sheet p{margin:0;color:var(--muted)}
.toast{position:fixed;left:50%;top:14px;transform:translateX(-50%) translateY(calc(-100% - 24px));visibility:hidden;background:#253555;color:#fff;padding:10px 16px;border-radius:12px;font-weight:700;transition:transform .25s,visibility .25s;z-index:60;max-width:92vw;text-align:center}
.toast.on{transform:translateX(-50%) translateY(0);visibility:visible}
.toast.err{background:#7A2430}
.offline-msg{display:none;position:fixed;left:0;right:0;bottom:0;background:#7A2430;color:#fff;text-align:center;padding:10px;font-weight:700;z-index:40}
body.offline .offline-msg{display:block}
body.offline .needs-conn{opacity:.4;pointer-events:none}
/* ---------- BỐ CỤC: thanh trên + tab cố định, nội dung tab tự cuộn ---------- */
[hidden]{display:none!important}
.subnav{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;position:sticky;top:0;z-index:3;background:var(--bg);padding:2px 0 6px;margin-bottom:-4px}
.subnav::-webkit-scrollbar{display:none}
.subnav button{flex:1 0 auto;padding:9px 12px;font-size:13px;border-radius:999px;background:var(--panel);color:var(--muted);white-space:nowrap}
.subnav button.on{background:#25406E;color:#fff;box-shadow:inset 0 0 0 1px var(--accent)}
html,body{overflow:hidden}
body{height:100%;height:100dvh;min-height:0}
main{min-height:0;overflow:hidden}
section.tab{overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-bottom:6px}
.sheet{max-height:calc(100% - 10px);overflow-y:auto}
.vis{display:flex;align-items:center;gap:6px;padding:7px 10px;font-size:12px;border-radius:999px;background:#1E5631;color:#C9F7D5;white-space:nowrap}
.vis.off{background:#5A1F27;color:#FFD6D8}
.vis i{width:8px;height:8px;border-radius:50%;background:currentColor}
/* Màn ngang: các thẻ chia cột, xem trước overlay nằm cố định bên trái. */
@media (orientation:landscape) and (min-width:600px){
 #tab-info.on,#tab-system.on{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));align-content:start;align-items:start;gap:10px}
 #tab-info>.subnav{grid-column:1/-1}
 #tab-overlay.on{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);align-content:start;align-items:start;gap:10px}
 #tab-overlay>.preview{grid-column:1;grid-row:1/span 5;position:sticky;top:0}
 #tab-overlay>.subnav,#tab-overlay>.card{grid-column:2}
}
/* Điện thoại xoay ngang (thấp): tiêu đề và tab chung một hàng. */
@media (orientation:landscape) and (max-height:500px){
 body{display:grid;grid-template-columns:auto minmax(0,1fr);grid-template-rows:auto minmax(0,1fr)}
 header{grid-column:1;grid-row:1;padding:6px 6px 6px max(10px,env(safe-area-inset-left))}
 header .title small{display:none}
 header .title b{font-size:15px;max-width:22vw}
 .conn span{display:none}
 nav{grid-column:2;grid-row:1;padding:6px max(10px,env(safe-area-inset-right)) 6px 4px}
 nav button{padding:8px 4px}
 main{grid-column:1/-1;grid-row:2;padding:0 max(10px,env(safe-area-inset-right)) 8px max(10px,env(safe-area-inset-left))}
 .sheet{display:grid;grid-template-columns:1fr 1fr;max-width:640px;padding-top:12px}
 .sheet>h3,.sheet>p,.sheet>label,.sheet>.grid2{grid-column:1/-1}
}
</style>
</head>
<body>
<header>
  <div class="title"><b id="hTitle">Bảng điểm</b><small id="hSub">VNVAR Camera Station</small></div>
  <button class="vis needs-conn" id="hVisible" title="Hiện/ẩn overlay trên OBS và livestream"><i></i><span id="hVisibleText">Overlay</span></button>
  <div class="conn" id="conn"><i></i><span id="connText">Đang kết nối…</span></div>
</header>
<nav id="nav">
  <button data-tab="score" class="on">Tỉ số</button>
  <button data-tab="info">Trận đấu</button>
  <button data-tab="overlay">Overlay</button>
  <button data-tab="system">Hệ thống</button>
</nav>
<main>
  <!-- ===================== SCORE ===================== -->
  <section class="tab on" id="tab-score">
    <div class="finished" id="finishedBox"></div>
    <div class="board needs-conn" id="board">
      <div class="team" id="teamA" data-team="A">
        <div class="row"><span class="name" id="nameA">Đội A</span><span class="serve" id="serveA">GIAO</span></div>
        <div class="players" id="playersA"></div>
        <div class="pts" id="ptsA">0</div>
        <div class="row"><div class="chips" id="chipsA"></div><span style="flex:1"></span><button class="minus" data-minus="A"><span class="fill"></span><span style="position:relative">Giữ −1</span></button></div>
      </div>
      <div class="mid">
        <div><div class="set" id="setLabel">Set 1</div><div class="hint" id="ruleHint"></div></div>
        <div class="callout" id="callout">0-0</div>
      </div>
      <div class="team" id="teamB" data-team="B">
        <div class="row"><span class="name" id="nameB">Đội B</span><span class="serve" id="serveB">GIAO</span></div>
        <div class="players" id="playersB"></div>
        <div class="pts" id="ptsB">0</div>
        <div class="row"><div class="chips" id="chipsB"></div><span style="flex:1"></span><button class="minus" data-minus="B"><span class="fill"></span><span style="position:relative">Giữ −1</span></button></div>
      </div>
    </div>
    <div class="actions needs-conn">
      <button class="primary" id="btnUndo">↶ Hoàn tác</button>
      <button id="btnServe">Đổi giao</button>
      <button id="btnMore">Thêm…</button>
    </div>
  </section>

  <!-- ===================== INFO ===================== -->
  <section class="tab" id="tab-info">
    <div class="subnav" role="tablist">
      <button data-sub="match" class="on">Thông tin trận</button>
      <button data-sub="teams">Hai đội</button>
      <button data-sub="rules">Môn &amp; luật</button>
    </div>
    <div class="card needs-conn" id="formMatch" data-sub="match">
      <h3>Thông tin trận</h3>
      <label class="f">Tên giải<input id="fTournament" maxlength="60" placeholder="VD: Giải Pickleball Mở rộng"></label>
      <div class="grid2">
        <label class="f">Vòng đấu<input id="fRound" maxlength="40" placeholder="VD: Bán kết"></label>
        <label class="f">Sân<input id="fCourt" maxlength="30" placeholder="VD: Sân 2"></label>
      </div>
      <button class="primary" id="saveMatch">Lưu thông tin trận</button>
    </div>
    <div class="card needs-conn" id="formTeamA" data-team="A" data-sub="teams">
      <h3><span class="dot" id="dotA"></span>Đội A</h3>
      <div class="grid2">
        <label class="f">Tên đội<input data-k="name" maxlength="40"></label>
        <label class="f">Tên ngắn (≤6)<input data-k="short" maxlength="6"></label>
      </div>
      <div class="grid2">
        <label class="f">VĐV 1<input data-k="p1" maxlength="40"></label>
        <label class="f">VĐV 2<input data-k="p2" maxlength="40"></label>
      </div>
      <div class="grid2">
        <label class="f">Màu đội<input type="color" data-k="color"></label>
        <div class="logo-row"><img alt="" data-logo><div style="display:flex;flex-direction:column;gap:6px;flex:1"><button class="ghost" data-pick>Chọn logo</button><button class="ghost" data-remove>Gỡ logo</button></div></div>
      </div>
      <input type="file" accept="image/*" data-file hidden>
      <button class="primary" data-save>Lưu Đội A</button>
    </div>
    <div class="card needs-conn" id="formTeamB" data-team="B" data-sub="teams">
      <h3><span class="dot" id="dotB"></span>Đội B</h3>
      <div class="grid2">
        <label class="f">Tên đội<input data-k="name" maxlength="40"></label>
        <label class="f">Tên ngắn (≤6)<input data-k="short" maxlength="6"></label>
      </div>
      <div class="grid2">
        <label class="f">VĐV 1<input data-k="p1" maxlength="40"></label>
        <label class="f">VĐV 2<input data-k="p2" maxlength="40"></label>
      </div>
      <div class="grid2">
        <label class="f">Màu đội<input type="color" data-k="color"></label>
        <div class="logo-row"><img alt="" data-logo><div style="display:flex;flex-direction:column;gap:6px;flex:1"><button class="ghost" data-pick>Chọn logo</button><button class="ghost" data-remove>Gỡ logo</button></div></div>
      </div>
      <input type="file" accept="image/*" data-file hidden>
      <button class="primary" data-save>Lưu Đội B</button>
    </div>
    <div class="card needs-conn" id="formRules" data-sub="rules">
      <h3>Môn &amp; luật</h3>
      <label class="f">Môn thi đấu<select id="rSport"><option value="pickleball">Pickleball</option><option value="badminton">Cầu lông</option><option value="tennis">Tennis</option><option value="custom">Tùy chỉnh</option></select></label>
      <div class="grid2 r-points">
        <label class="f">Điểm thắng set<input id="rPoints" type="number" inputmode="numeric" min="1" max="99"></label>
        <label class="f">Cách biệt<input id="rWinBy" type="number" inputmode="numeric" min="1" max="5"></label>
      </div>
      <div class="grid2 r-points">
        <label class="f">Điểm trần (trống = không)<input id="rCap" type="number" inputmode="numeric" min="1" max="199"></label>
        <label class="f">Cách tính điểm<select id="rScoring"><option value="sideout">Chỉ đội giao được điểm</option><option value="rally">Pha nào cũng có điểm</option></select></label>
      </div>
      <div class="grid3 r-tennis">
        <label class="f">Game/set<input id="rGames" type="number" inputmode="numeric" min="1" max="10"></label>
        <label class="f">Tie-break khi<input id="rTbAt" type="number" inputmode="numeric" min="1" max="10"></label>
        <label class="f">Điểm tie-break<input id="rTbPts" type="number" inputmode="numeric" min="1" max="20"></label>
      </div>
      <div class="grid2">
        <label class="f">Số set<select id="rBestOf"><option value="1">1 set</option><option value="3">Thắng 2/3</option><option value="5">Thắng 3/5</option><option value="7">Thắng 4/7</option></select></label>
        <label class="check"><input type="checkbox" id="rDoubles">Đánh đôi</label>
      </div>
      <div class="grid2">
        <button class="ghost" id="rPreset">Luật chuẩn</button>
        <button class="primary" id="rApply">Áp dụng luật</button>
      </div>
      <div class="muted">Đổi luật khi trận đang có điểm sẽ bắt đầu lại trận.</div>
    </div>
  </section>

  <!-- ===================== OVERLAY ===================== -->
  <section class="tab" id="tab-overlay">
    <div class="preview" id="preview"><iframe id="previewFrame" title="Xem trước overlay" tabindex="-1"></iframe></div>
    <div class="subnav" role="tablist">
      <button data-sub="live" class="on">Trực tiếp</button>
      <button data-sub="look">Giao diện</button>
      <button data-sub="ticker">Chữ chạy</button>
      <button data-sub="stream">Livestream</button>
    </div>
    <!-- Trực tiếp: thao tác trong lúc trận đấu -->
    <div class="card needs-conn" data-sub="live">
      <h3>Cảnh đang phát</h3>
      <label class="check"><input type="checkbox" id="oVisible">Hiện overlay (bảng tỉ số, thông báo, chữ chạy)</label>
      <div class="seg" id="scenes" style="grid-template-columns:repeat(3,1fr)">
        <button data-scene="scorebar">Thanh tỉ số</button>
        <button data-scene="full">Bảng lớn</button>
        <button data-scene="intro">Giới thiệu</button>
        <button data-scene="result">Kết quả</button>
        <button data-scene="hidden">Ẩn tất cả</button>
      </div>
    </div>
    <div class="card needs-conn" data-sub="live">
      <h3>Thông báo nhanh</h3>
      <div class="seg" style="grid-template-columns:1fr 1fr">
        <button data-banner="TẠM DỪNG · TIMEOUT">Timeout</button>
        <button data-banner="NGHỈ GIỮA SET">Nghỉ giữa set</button>
        <button data-banner="ĐANG KIỂM TRA VAR">Kiểm tra VAR</button>
        <button data-banner="ĐỔI SÂN">Đổi sân</button>
      </div>
      <label class="f">Nội dung khác<input id="bText" maxlength="80" placeholder="Nhập thông báo"></label>
      <div class="grid2">
        <label class="f">Hiển thị<select id="bSeconds"><option value="10">10 giây</option><option value="30" selected>30 giây</option><option value="60">1 phút</option><option value="0">Đến khi tắt</option></select></label>
        <div style="display:flex;gap:8px;align-items:flex-end"><button class="primary" id="bShow" style="flex:1">Hiện</button><button class="danger" id="bClear" style="flex:1">Tắt</button></div>
      </div>
    </div>
    <div class="card needs-conn" data-sub="live">
      <h3>Đồng hồ trận</h3>
      <div class="timerv" id="timerView">00:00</div>
      <div class="grid3"><button class="primary" data-timer="start">Bắt đầu</button><button data-timer="pause">Tạm dừng</button><button class="danger" data-timer="reset">Đặt lại</button></div>
    </div>
    <!-- Giao diện: chỉnh trước trận -->
    <div class="card needs-conn" data-sub="look">
      <h3>Vị trí &amp; kích thước</h3>
      <div class="seg" id="positions" style="grid-template-columns:repeat(3,1fr)">
        <button data-pos="tl">↖ Trên trái</button><button data-pos="tc">↑ Trên giữa</button><button data-pos="tr">↗ Trên phải</button>
        <button data-pos="bl">↙ Dưới trái</button><button data-pos="bc">↓ Dưới giữa</button><button data-pos="br">↘ Dưới phải</button>
      </div>
      <label class="f"><span>Kích thước: <b id="oScaleV">100%</b></span><input type="range" id="oScale" min="0.5" max="2" step="0.05"></label>
    </div>
    <div class="card needs-conn" data-sub="look">
      <h3>Màu sắc</h3>
      <div class="seg" id="themes" style="grid-template-columns:repeat(3,1fr)">
        <button data-theme="dark">Tối</button><button data-theme="light">Sáng</button><button data-theme="glass">Kính mờ</button>
      </div>
      <label class="f">Màu nhấn<input type="color" id="oAccent"></label>
    </div>
    <div class="card needs-conn" data-sub="look">
      <h3>Thông tin hiển thị</h3>
      <label class="check"><input type="checkbox" data-show="sets">Hiện điểm các set</label>
      <label class="check"><input type="checkbox" data-show="serve">Hiện đội giao bóng</label>
      <label class="check"><input type="checkbox" data-show="tournament">Hiện tên giải / sân</label>
      <label class="check"><input type="checkbox" data-show="timer">Hiện đồng hồ trận</label>
    </div>
    <!-- Chữ chạy -->
    <div class="card needs-conn" id="formTicker" data-sub="ticker">
      <h3>Chữ chạy</h3>
      <label class="check"><input type="checkbox" id="tEnabled">Bật chữ chạy</label>
      <label class="f">Nội dung<textarea id="tText" rows="2" maxlength="200" placeholder="VD: Tài trợ bởi ..."></textarea></label>
      <label class="f">Tốc độ<select id="tSpeed"><option value="1">Chậm</option><option value="2">Vừa</option><option value="3">Nhanh</option></select></label>
      <button class="primary" id="tSave">Cập nhật chữ chạy</button>
      <div class="muted">Livestream từ điện thoại: nội dung đổi ngay; tốc độ mới áp dụng từ lần phát hoặc kết nối lại sau.</div>
    </div>
    <!-- Livestream từ điện thoại camera -->
    <div class="card needs-conn" data-sub="stream">
      <h3>Livestream từ điện thoại</h3>
      <label class="check"><input type="checkbox" id="oBurnIn">In bảng tỉ số vào video livestream</label>
      <div class="muted">Áp dụng cho phát RTMP/RTSP trên điện thoại Android và iPhone, không cần OBS. Bật/tắt khi đang phát sẽ khởi động lại luồng vài giây. Video ghi và Tablet không bị ảnh hưởng.</div>
    </div>
  </section>

  <!-- ===================== SYSTEM ===================== -->
  <section class="tab" id="tab-system">
    <div class="card">
      <h3>Link overlay cho OBS</h3>
      <div class="mono" id="sOverlay"></div>
      <button class="primary" data-copy="sOverlay">Sao chép link overlay</button>
      <div class="muted">OBS → Sources → + → Browser → dán link, Width 1920, Height 1080. Nền overlay trong suốt.</div>
    </div>
    <div class="card">
      <h3>Link điều khiển (có mã)</h3>
      <div class="mono" id="sControl"></div>
      <button data-copy="sControl">Sao chép link điều khiển</button>
      <div class="muted">Ai có link này đều chỉnh được tỉ số. Đổi mã trong app Camera Station nếu bị lộ.</div>
    </div>
    <div class="card">
      <h3>Kết nối</h3>
      <div class="muted" id="sInfo"></div>
      <button class="ghost" id="sKey">Nhập mã điều khiển khác</button>
      <button class="ghost" id="sReload">Tải lại trang</button>
    </div>
  </section>
</main>

<div class="offline-msg">Mất kết nối với camera · đang thử lại…</div>
<div class="toast" id="toast"></div>

<div class="shade" id="moreSheet"><div class="sheet">
  <h3>Thao tác</h3>
  <div class="grid2" id="serveBtns"></div>
  <button id="mSwapSides">Đổi bên sân</button>
  <button id="mEndSet">Kết thúc set hiện tại</button>
  <button id="mFinish" class="danger">Kết thúc trận</button>
  <button id="mReopen">Mở lại trận</button>
  <button id="mNew" class="danger">Trận mới (về 0)</button>
  <button class="ghost" data-close>Đóng</button>
</div></div>

<div class="shade" id="confirmSheet"><div class="sheet">
  <h3 id="cTitle">Xác nhận</h3>
  <p id="cText"></p>
  <div class="grid2"><button class="ghost" id="cNo">Hủy</button><button class="danger" id="cYes">Đồng ý</button></div>
</div></div>

<div class="shade" id="keySheet"><div class="sheet">
  <h3>Mã điều khiển</h3>
  <p>Mã không đúng hoặc đã được đổi. Quét lại mã QR trên app Camera Station hoặc nhập mã 6 ký tự.</p>
  <label class="f"><input id="keyInput" maxlength="6" autocapitalize="characters" autocomplete="off" placeholder="VD: AB12CD"></label>
  <div class="grid2"><button class="ghost" data-close>Đóng</button><button class="primary" id="keySave">Lưu mã</button></div>
</div></div>

<script>
(function(){
'use strict';
var KEY_STORE='vnvar_score_key';
var state=null, key='', es=null, lastSeen=0, connected=false, offset=0, seq=0;
var dirty={match:false,A:false,B:false,rules:false,ticker:false};
var $=function(id){return document.getElementById(id);};
var qsa=function(sel,root){return Array.prototype.slice.call((root||document).querySelectorAll(sel));};

// ---------- key ----------
function readKey(){
  var k='';
  try{var u=new URL(location.href);k=(u.searchParams.get('k')||'').trim().toUpperCase();
    if(k){try{localStorage.setItem(KEY_STORE,k);}catch(e){}
      u.searchParams.delete('k');history.replaceState(null,'',u.pathname+u.search+u.hash);}
  }catch(e){}
  if(!k){try{k=(localStorage.getItem(KEY_STORE)||'').toUpperCase();}catch(e){}}
  return k;
}
key=readKey();

// ---------- ui helpers ----------
var toastTimer=0;
function toast(msg,err){var t=$('toast');t.textContent=msg;t.className='toast on'+(err?' err':'');clearTimeout(toastTimer);toastTimer=setTimeout(function(){t.className='toast'+(err?' err':'');},2600);}
function openSheet(id){$(id).classList.add('on');}
function closeSheets(){qsa('.shade').forEach(function(s){s.classList.remove('on');});}
qsa('.shade').forEach(function(s){s.addEventListener('click',function(e){if(e.target===s||e.target.hasAttribute('data-close'))s.classList.remove('on');});});
var confirmCb=null;
function confirmBox(title,text,yes,cb){$('cTitle').textContent=title;$('cText').textContent=text;$('cYes').textContent=yes||'Đồng ý';confirmCb=cb;closeSheets();openSheet('confirmSheet');}
$('cNo').onclick=function(){confirmCb=null;closeSheets();};
$('cYes').onclick=function(){var cb=confirmCb;confirmCb=null;closeSheets();if(cb)cb();};
function setText(id,v){var el=$(id);if(el&&el.textContent!==v)el.textContent=v;}

// ---------- tabs ----------
qsa('#nav button').forEach(function(b){b.onclick=function(){
  qsa('#nav button').forEach(function(x){x.classList.toggle('on',x===b);});
  qsa('section.tab').forEach(function(s){s.classList.toggle('on',s.id==='tab-'+b.dataset.tab);});
  if(b.dataset.tab==='overlay')ensurePreview();
};});

// ---------- sub tabs (mỗi tab chia nhóm, nhớ nhóm đang mở) ----------
qsa('section.tab').forEach(function(sec){
  var nav=sec.querySelector('.subnav');if(!nav)return;
  var store='vnvarSub:'+sec.id;
  function pick(name){
    var found=false;
    qsa('button',nav).forEach(function(x){var on=x.dataset.sub===name;x.classList.toggle('on',on);if(on)found=true;});
    if(!found)return false;
    qsa('[data-sub]',sec).forEach(function(el){if(el.parentNode!==nav)el.hidden=el.dataset.sub!==name;});
    try{sessionStorage.setItem(store,name);}catch(e){}
    return true;
  }
  qsa('button',nav).forEach(function(b){b.onclick=function(){pick(b.dataset.sub);sec.scrollTop=0;};});
  var saved=null;try{saved=sessionStorage.getItem(store);}catch(e){}
  if(!saved||!pick(saved))pick(nav.querySelector('button').dataset.sub);
});

// ---------- network ----------
function uid(){seq+=1;return Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,8)+'-'+seq;}
function sleep(ms){return new Promise(function(r){setTimeout(r,ms);});}
function send(action){
  var body=Object.assign({id:uid()},action);
  var attempt=0;
  function once(){
    return fetch('/api/score',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-Score-Key':key},body:JSON.stringify(body)})
    .then(function(r){return r.json().catch(function(){return null;}).then(function(d){return {r:r,d:d};});})
    .then(function(x){
      if(x.r.ok){if(x.d&&x.d.state)applyState(x.d.state);return true;}
      if(x.r.status===401){openKey();return false;}
      if(x.r.status===429){toast('Bấm quá nhanh, vui lòng chờ một chút',true);return false;}
      if(x.r.status===503&&attempt<3){attempt+=1;return sleep(600*attempt).then(once);}
      toast((x.d&&x.d.message)||('Lỗi '+x.r.status),true);return false;
    },function(){
      if(attempt<3){attempt+=1;return sleep(500*attempt).then(once);}
      toast('Không gửi được lệnh tới camera',true);return false;
    });
  }
  return once();
}
function applyState(s){
  if(!s||typeof s.rev!=='number')return;
  if(state&&s.epoch===state.epoch&&s.rev<state.rev)return;
  if(typeof s.serverNowMs==='number')offset=s.serverNowMs-Date.now();
  state=s;render();
}
function setConn(on){
  connected=on;
  $('conn').classList.toggle('on',on);
  setText('connText',on?'Đã kết nối':'Mất kết nối');
  document.body.classList.toggle('offline',!on&&state!==null);
}
function connect(){
  if(es){try{es.close();}catch(e){}}
  es=new EventSource('/api/score/events');
  es.addEventListener('state',function(e){lastSeen=Date.now();setConn(true);try{applyState(JSON.parse(e.data));}catch(err){}});
  es.addEventListener('ping',function(){lastSeen=Date.now();setConn(true);});
  es.onerror=function(){setConn(false);};
}
function poll(){
  return fetch('/api/score',{cache:'no-store'}).then(function(r){return r.json();}).then(function(s){applyState(s);}).catch(function(){});
}
setInterval(function(){
  if(Date.now()-lastSeen>25000){setConn(false);connect();poll();}
},5000);
connect();poll();

// ---------- render ----------
function teamOf(id){return id==='A'?state.teamA:state.teamB;}
function render(){
  var s=state, sport=s.sport, tennis=sport==='tennis';
  var m=s.match||{};
  setText('hTitle',m.tournament||'Bảng điểm');
  var sub=[m.round,m.court].filter(Boolean).join(' · ');
  setText('hSub',sub||'VNVAR Camera Station');
  // panels order
  var board=$('board'), A=$('teamA'), B=$('teamB'), mid=board.querySelector('.mid');
  if(s.sidesSwapped){if(board.firstElementChild!==B){board.insertBefore(B,A);board.insertBefore(mid,A);}}
  else if(board.firstElementChild!==A){board.insertBefore(A,B);board.insertBefore(mid,B);}
  ['A','B'].forEach(function(id){
    var t=teamOf(id), el=$('team'+id), low=id.toLowerCase();
    el.style.background=t.color;
    setText('name'+id,t.name);
    setText('players'+id,(t.players||[]).join(' · '));
    var pts=s.display[low];
    var ptsEl=$('pts'+id);
    if(ptsEl.textContent!==pts){ptsEl.textContent=pts;}
    $('serve'+id).classList.toggle('on',s.serving===id);
    $('serve'+id).textContent=(s.rules.doubles&&s.rules.scoring==='sideout'&&!tennis)?('GIAO '+s.serverNumber):'GIAO';
    var chips=$('chips'+id);chips.textContent='';
    var won=s.setsWon[low];
    var c=document.createElement('span');c.className='chip';c.textContent='Set thắng: '+won;chips.appendChild(c);
    if(tennis){var g=document.createElement('span');g.className='chip';g.textContent='Game: '+s.games[low];chips.appendChild(g);}
    $('dot'+id).style.background=t.color;
  });
  setText('setLabel',s.status==='finished'?'Hết trận':('Set '+s.currentSet+(tennis&&s.tiebreak?' · Tie-break':'')));
  setText('callout',s.display.callout);
  var hint='';
  if(sport==='pickleball'&&s.rules.scoring==='sideout')hint='Chạm vào đội thắng pha bóng';
  else if(tennis)hint='Chạm vào người thắng điểm';
  else hint='Chạm để +1 điểm';
  setText('ruleHint',hint);
  var fb=$('finishedBox');
  if(s.status==='finished'){var w=s.winner?teamOf(s.winner).name:'';fb.textContent=w?('🏆 '+w+' thắng '+s.setsWon.a+'–'+s.setsWon.b):'Trận đã kết thúc';fb.classList.add('on');}
  else fb.classList.remove('on');
  $('mReopen').style.display=s.status==='finished'?'':'none';
  renderServeButtons();
  fillForms();
  renderOverlayTab();
  renderSystem();
}
function renderServeButtons(){
  var box=$('serveBtns');box.textContent='';
  var s=state, doubles=s.rules.doubles&&s.rules.scoring==='sideout'&&s.sport!=='tennis';
  ['A','B'].forEach(function(id){
    var nums=doubles?[1,2]:[null];
    nums.forEach(function(n){
      var b=document.createElement('button');
      b.textContent='Giao: '+teamOf(id).short+(n?(' · '+n):'');
      if(s.serving===id&&(!n||s.serverNumber===n))b.className='primary';
      b.onclick=function(){closeSheets();var a={action:'setServe',team:id};if(n)a.serverNumber=n;send(a);};
      box.appendChild(b);
    });
  });
  box.style.gridTemplateColumns=doubles?'1fr 1fr':'1fr 1fr';
}

// ---------- score input ----------
var lastTap={A:0,B:0};
['A','B'].forEach(function(id){
  var el=$('team'+id);
  el.addEventListener('click',function(e){
    if(e.target.closest('.minus'))return;
    var now=Date.now();if(now-lastTap[id]<350)return;lastTap[id]=now;
    if(!state||state.status==='finished'){if(state)toast('Trận đã kết thúc',true);return;}
    el.classList.remove('flash');void el.offsetWidth;el.classList.add('flash');
    send({action:'point',team:id});
  });
});
qsa('.minus').forEach(function(btn){
  var timer=0;
  function cancel(){clearTimeout(timer);timer=0;btn.classList.remove('holding');}
  btn.addEventListener('pointerdown',function(e){e.preventDefault();e.stopPropagation();cancel();btn.classList.add('holding');
    timer=setTimeout(function(){cancel();send({action:'adjust',team:btn.dataset.minus,delta:-1});toast('Đã trừ 1 điểm');},600);});
  ['pointerup','pointerleave','pointercancel'].forEach(function(ev){btn.addEventListener(ev,cancel);});
  btn.addEventListener('click',function(e){e.stopPropagation();});
  btn.addEventListener('contextmenu',function(e){e.preventDefault();});
});
$('btnUndo').onclick=function(){send({action:'undo'});};
$('btnServe').onclick=function(){send({action:'swapServe'});};
$('btnMore').onclick=function(){openSheet('moreSheet');};
$('mSwapSides').onclick=function(){closeSheets();send({action:'swapSides'});};
$('mEndSet').onclick=function(){confirmBox('Kết thúc set?','Set hiện tại sẽ được chốt theo tỉ số đang có.','Kết thúc set',function(){send({action:'endSet'});});};
$('mFinish').onclick=function(){confirmBox('Kết thúc trận?','Trận sẽ được chốt theo số set đã thắng.','Kết thúc trận',function(){send({action:'finish'});});};
$('mReopen').onclick=function(){closeSheets();send({action:'reopen'});};
$('mNew').onclick=function(){confirmBox('Bắt đầu trận mới?','Điểm, set và đồng hồ về 0. Tên đội và giao diện được giữ nguyên.','Trận mới',function(){send({action:'newMatch'});});};

// ---------- forms ----------
function markDirty(form,name){form.addEventListener('input',function(){dirty[name]=true;});form.addEventListener('change',function(){dirty[name]=true;});}
markDirty($('formMatch'),'match');markDirty($('formTeamA'),'A');markDirty($('formTeamB'),'B');markDirty($('formRules'),'rules');markDirty($('formTicker'),'ticker');
function val(el,v){if(el.value!==String(v))el.value=v;}
function fillForms(){
  var s=state;
  if(!dirty.match){val($('fTournament'),s.match.tournament||'');val($('fRound'),s.match.round||'');val($('fCourt'),s.match.court||'');}
  ['A','B'].forEach(function(id){
    var form=$('formTeam'+id), t=teamOf(id);
    var img=form.querySelector('[data-logo]');
    if(t.logoId){var src='/api/score/logo/'+encodeURIComponent(t.logoId);if(img.getAttribute('src')!==src)img.setAttribute('src',src);img.style.visibility='visible';}
    else{img.removeAttribute('src');img.style.visibility='hidden';}
    if(dirty[id])return;
    form.querySelector('[data-k=name]').value=t.name;
    form.querySelector('[data-k=short]').value=t.short;
    form.querySelector('[data-k=p1]').value=(t.players||[])[0]||'';
    form.querySelector('[data-k=p2]').value=(t.players||[])[1]||'';
    form.querySelector('[data-k=color]').value=t.color.toLowerCase();
  });
  if(!dirty.rules){
    var r=s.rules;
    val($('rSport'),s.sport);val($('rPoints'),r.pointsToWin);val($('rWinBy'),r.winBy);val($('rCap'),r.cap==null?'':r.cap);
    val($('rScoring'),r.scoring);val($('rBestOf'),r.bestOf);$('rDoubles').checked=!!r.doubles;
    val($('rGames'),r.gamesPerSet);val($('rTbAt'),r.tiebreakAt);val($('rTbPts'),r.tiebreakPoints);
  }
  toggleRuleFields();
  if(!dirty.ticker){var tk=s.overlay.ticker;$('tEnabled').checked=!!tk.enabled;val($('tText'),tk.text||'');val($('tSpeed'),tk.speed);}
}
function toggleRuleFields(){
  var tennis=$('rSport').value==='tennis';
  qsa('.r-points').forEach(function(e){e.style.display=tennis?'none':'';});
  qsa('.r-tennis').forEach(function(e){e.style.display=tennis?'':'none';});
}
$('rSport').addEventListener('change',toggleRuleFields);
$('saveMatch').onclick=function(){send({action:'setMatchInfo',tournament:$('fTournament').value,round:$('fRound').value,court:$('fCourt').value}).then(function(ok){if(ok){dirty.match=false;toast('Đã lưu thông tin trận');render();}});};
['A','B'].forEach(function(id){
  var form=$('formTeam'+id);
  form.querySelector('[data-save]').onclick=function(){
    var g=function(k){return form.querySelector('[data-k='+k+']').value;};
    var name=g('name').trim();if(!name){toast('Tên đội không được để trống',true);return;}
    send({action:'setTeam',team:id,name:name,short:g('short').trim(),color:g('color').toUpperCase(),players:[g('p1'),g('p2')]})
    .then(function(ok){if(ok){dirty[id]=false;toast('Đã lưu '+name);render();}});
  };
  var file=form.querySelector('[data-file]');
  form.querySelector('[data-pick]').onclick=function(){file.click();};
  form.querySelector('[data-remove]').onclick=function(){send({action:'removeLogo',team:id});};
  file.onchange=function(){var f=file.files&&file.files[0];file.value='';if(f)uploadLogo(id,f);};
});
function uploadLogo(team,f){
  toast('Đang xử lý logo…');
  var url=URL.createObjectURL(f), img=new Image();
  img.onload=function(){
    var max=256, w=img.naturalWidth, h=img.naturalHeight, k=Math.min(1,max/Math.max(w,h));
    var c=document.createElement('canvas');c.width=Math.max(1,Math.round(w*k));c.height=Math.max(1,Math.round(h*k));
    c.getContext('2d').drawImage(img,0,0,c.width,c.height);URL.revokeObjectURL(url);
    c.toBlob(function(blob){
      if(!blob){toast('Không đọc được ảnh',true);return;}
      fetch('/api/score/logo?team='+team,{method:'POST',headers:{'Content-Type':'image/png','X-Score-Key':key},body:blob})
      .then(function(r){return r.json().catch(function(){return null;}).then(function(d){
        if(r.ok){if(d&&d.state)applyState(d.state);toast('Đã cập nhật logo');}
        else if(r.status===401)openKey();
        else toast((d&&d.message)||('Lỗi '+r.status),true);
      });}).catch(function(){toast('Không tải được logo lên',true);});
    },'image/png');
  };
  img.onerror=function(){URL.revokeObjectURL(url);toast('File không phải ảnh',true);};
  img.src=url;
}
function readRules(){
  var n=function(id){var v=$(id).value.trim();return v===''?null:Number(v);};
  return {pointsToWin:n('rPoints'),winBy:n('rWinBy'),cap:n('rCap'),bestOf:Number($('rBestOf').value),scoring:$('rScoring').value,doubles:$('rDoubles').checked,gamesPerSet:n('rGames'),tiebreakAt:n('rTbAt'),tiebreakPoints:n('rTbPts')};
}
function pristine(){var s=state;return s.points.a===0&&s.points.b===0&&s.games.a===0&&s.games.b===0&&s.sets.length===0&&s.status!=='finished';}
function sendConfig(extra){
  var a=Object.assign({action:'config',sport:$('rSport').value},extra);
  var go=function(reset){if(reset)a.reset=true;send(a).then(function(ok){if(ok){dirty.rules=false;toast('Đã áp dụng luật');render();}});};
  if(pristine())go(false);
  else confirmBox('Đổi luật và bắt đầu lại?','Trận đang có điểm. Áp dụng luật mới sẽ đưa tỉ số về 0.','Bắt đầu lại',function(){go(true);});
}
$('rApply').onclick=function(){
  var r=readRules();
  ['pointsToWin','winBy','gamesPerSet','tiebreakAt','tiebreakPoints'].forEach(function(k){if(r[k]==null)delete r[k];});
  sendConfig({rules:r});
};
$('rPreset').onclick=function(){sendConfig({preset:true});};

// ---------- overlay tab ----------
var previewLoaded=false;
function ensurePreview(){
  if(!previewLoaded){previewLoaded=true;$('previewFrame').src='/overlay?preview=1';}
  fitPreview();
}
function fitPreview(){var box=$('preview');var k=box.clientWidth/1920;$('previewFrame').style.transform='scale('+k+')';}
window.addEventListener('resize',fitPreview);
function renderOverlayTab(){
  var o=state.overlay;
  qsa('#scenes button').forEach(function(b){b.classList.toggle('on',b.dataset.scene===o.scene);});
  qsa('#themes button').forEach(function(b){b.classList.toggle('on',b.dataset.theme===o.theme);});
  qsa('#positions button').forEach(function(b){b.classList.toggle('on',b.dataset.pos===o.position);});
  if(document.activeElement!==$('oAccent'))val($('oAccent'),o.accent.toLowerCase());
  if(document.activeElement!==$('oScale'))val($('oScale'),o.scale);
  setText('oScaleV',Math.round(Number(o.scale)*100)+'%');
  qsa('[data-show]').forEach(function(c){c.checked=!!o.show[c.dataset.show];});
  $('oBurnIn').checked=o.burnIn!==false;
  $('oVisible').checked=o.visible!==false;
  $('hVisible').classList.toggle('off',o.visible===false);
  setText('hVisibleText',o.visible===false?'Overlay: Ẩn':'Overlay: Hiện');
}
qsa('#scenes button').forEach(function(b){b.onclick=function(){send({action:'overlay',scene:b.dataset.scene});};});
qsa('#themes button').forEach(function(b){b.onclick=function(){send({action:'overlay',theme:b.dataset.theme});};});
qsa('#positions button').forEach(function(b){b.onclick=function(){send({action:'overlay',position:b.dataset.pos});};});
$('oAccent').addEventListener('change',function(){send({action:'overlay',accent:$('oAccent').value.toUpperCase()});});
$('oScale').addEventListener('input',function(){setText('oScaleV',Math.round(Number($('oScale').value)*100)+'%');});
$('oScale').addEventListener('change',function(){send({action:'overlay',scale:Number($('oScale').value)});});
$('oBurnIn').addEventListener('change',function(){send({action:'overlay',burnIn:$('oBurnIn').checked});});
$('oVisible').addEventListener('change',function(){send({action:'overlay',visible:$('oVisible').checked});});
$('hVisible').onclick=function(){var hide=!(state&&state.overlay&&state.overlay.visible===false);send({action:'overlay',visible:!hide}).then(function(ok){if(ok)toast(hide?'Đã ẩn overlay':'Đã hiện overlay');});};
qsa('[data-show]').forEach(function(c){c.addEventListener('change',function(){var show={};show[c.dataset.show]=c.checked;send({action:'overlay',show:show});});});
$('tSave').onclick=function(){send({action:'overlay',ticker:{enabled:$('tEnabled').checked,text:$('tText').value,speed:Number($('tSpeed').value)}}).then(function(ok){if(ok){dirty.ticker=false;toast('Đã cập nhật chữ chạy');render();}});};
function showBanner(text){text=(text||'').trim();if(!text){toast('Nhập nội dung thông báo',true);return;}send({action:'banner',text:text,seconds:Number($('bSeconds').value)}).then(function(ok){if(ok)toast('Đang hiện: '+text);});}
qsa('[data-banner]').forEach(function(b){b.onclick=function(){showBanner(b.dataset.banner);};});
$('bShow').onclick=function(){showBanner($('bText').value);};
$('bClear').onclick=function(){send({action:'banner',text:''});};
qsa('[data-timer]').forEach(function(b){b.onclick=function(){
  var op=b.dataset.timer;
  if(op==='reset')confirmBox('Đặt lại đồng hồ?','Đồng hồ trận về 00:00.','Đặt lại',function(){send({action:'timer',op:'reset'});});
  else send({action:'timer',op:op});
};});
function fmt(ms){var t=Math.max(0,Math.floor(ms/1000)),h=Math.floor(t/3600),m=Math.floor(t%3600/60),s=t%60;var p=function(x){return(x<10?'0':'')+x;};return(h?h+':'+p(m):p(m))+':'+p(s);}
setInterval(function(){if(!state)return;var tm=state.timer;var ms=tm.accumulatedMs+(tm.running?Math.max(0,Date.now()+offset-tm.startedAtMs):0);setText('timerView',fmt(ms));},500);

// ---------- system ----------
function renderSystem(){
  setText('sOverlay',location.origin+'/overlay');
  setText('sControl',location.origin+'/control?k='+(key||'??????'));
  setText('sInfo','Trận: '+state.matchId+' · phiên bản dữ liệu '+state.rev+(key?'':' · CHƯA CÓ MÃ ĐIỀU KHIỂN'));
}
function copyText(text){
  if(navigator.clipboard&&window.isSecureContext){return navigator.clipboard.writeText(text).then(function(){return true;},function(){return fallbackCopy(text);});}
  return Promise.resolve(fallbackCopy(text));
}
function fallbackCopy(text){var t=document.createElement('textarea');t.value=text;t.setAttribute('readonly','');t.style.position='fixed';t.style.opacity='0';document.body.appendChild(t);t.select();t.setSelectionRange(0,text.length);var ok=false;try{ok=document.execCommand('copy');}catch(e){}document.body.removeChild(t);return ok;}
qsa('[data-copy]').forEach(function(b){b.onclick=function(){var text=$(b.dataset.copy).textContent;copyText(text).then(function(ok){toast(ok?'Đã sao chép':'Hãy nhấn giữ để sao chép thủ công',!ok);});};});
function openKey(){$('keyInput').value=key;closeSheets();openSheet('keySheet');}
$('sKey').onclick=openKey;
$('sReload').onclick=function(){location.reload();};
$('keySave').onclick=function(){var k=$('keyInput').value.trim().toUpperCase();if(!/^[A-Z0-9]{6}$/.test(k)){toast('Mã gồm 6 ký tự chữ/số',true);return;}key=k;try{localStorage.setItem(KEY_STORE,k);}catch(e){}closeSheets();toast('Đã lưu mã');if(state)renderSystem();};
if(!key)setTimeout(openKey,600);
})();
</script>
</body>
</html>
''';

/// Overlay trong suốt cho OBS Browser Source (`GET /overlay`).
const String scoreboardOverlayPageHtml = r'''<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<link rel="icon" href="data:,">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Overlay · VNVAR</title>
<style>
html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:100%;height:100%}
*{box-sizing:border-box}
#stage{position:absolute;left:0;top:0;width:1920px;height:1080px;transform-origin:0 0;font-family:"Segoe UI",Roboto,-apple-system,Arial,sans-serif;color:#fff;--accent:#FFC107;--u:1}
.theme-dark{--bg:rgba(10,16,28,.92);--bg2:rgba(255,255,255,.08);--fg:#fff;--muted:rgba(255,255,255,.7);--shadow:0 10px 30px rgba(0,0,0,.45)}
.theme-light{--bg:rgba(255,255,255,.95);--bg2:rgba(10,20,40,.07);--fg:#0E1726;--muted:rgba(14,23,38,.65);--shadow:0 10px 30px rgba(0,0,0,.25)}
.theme-glass{--bg:rgba(20,28,45,.55);--bg2:rgba(255,255,255,.12);--fg:#fff;--muted:rgba(255,255,255,.75);--shadow:0 10px 30px rgba(0,0,0,.35)}
.scene{position:absolute;opacity:0;visibility:hidden;transition:opacity .35s ease,transform .35s ease,visibility 0s linear .35s;color:var(--fg)}
.scene.on{opacity:1;visibility:visible;transition:opacity .35s ease,transform .35s ease,visibility 0s}
.num{font-variant-numeric:tabular-nums}
.bump{animation:bump .45s cubic-bezier(.2,.9,.3,1.3)}
@keyframes bump{0%{transform:translateY(-35%);opacity:0}100%{transform:none;opacity:1}}

/* ---------- SCOREBAR ---------- */
#scorebar{min-width:calc(560px*var(--u));max-width:calc(820px*var(--u));transform-origin:0 0}
#scorebar .box{background:var(--bg);border-radius:calc(14px*var(--u));box-shadow:var(--shadow);overflow:hidden;border-bottom:calc(4px*var(--u)) solid var(--accent)}
.theme-glass #scorebar .box,.theme-glass .panel{backdrop-filter:blur(8px)}
.sb-head{display:flex;gap:calc(14px*var(--u));align-items:center;padding:calc(7px*var(--u)) calc(16px*var(--u));font-size:calc(19px*var(--u));color:var(--muted);background:var(--bg2);white-space:nowrap}
.sb-head .t{flex:1;overflow:hidden;text-overflow:ellipsis;font-weight:700}
.sb-head .clock{font-weight:800;color:var(--fg)}
.sb-row{display:flex;align-items:stretch;height:calc(62px*var(--u))}
.sb-row+.sb-row{border-top:1px solid var(--bg2)}
.sb-color{width:calc(10px*var(--u))}
.sb-logo{width:calc(46px*var(--u));height:calc(46px*var(--u));object-fit:contain;align-self:center;margin-left:calc(10px*var(--u));display:none}
.sb-name{flex:1 1 auto;min-width:0;padding:0 calc(14px*var(--u));font-size:calc(30px*var(--u));line-height:calc(62px*var(--u));font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sb-serve{width:calc(26px*var(--u));display:flex;align-items:center;justify-content:center}
.sb-serve i{width:calc(14px*var(--u));height:calc(14px*var(--u));border-radius:50%;background:var(--accent);box-shadow:0 0 calc(10px*var(--u)) var(--accent);opacity:0;transition:opacity .25s}
.sb-serve.on i{opacity:1}
.sb-sets{display:flex}
.sb-sets span{width:calc(40px*var(--u));display:flex;align-items:center;justify-content:center;font-size:calc(24px*var(--u));color:var(--muted);font-weight:700}
.sb-sets span.win{color:var(--fg)}
.sb-games{width:calc(52px*var(--u));display:flex;align-items:center;justify-content:center;font-size:calc(28px*var(--u));font-weight:800;background:var(--bg2)}
.sb-pts{min-width:calc(84px*var(--u));padding:0 calc(10px*var(--u));display:flex;align-items:center;justify-content:center;font-size:calc(38px*var(--u));font-weight:900;background:var(--accent);color:#111}
.sb-pts span{display:inline-block}
.sb-foot{text-align:center;font-weight:800;font-size:calc(18px*var(--u));padding:calc(4px*var(--u));background:var(--bg2);color:var(--accent);display:none;letter-spacing:1px}
.sb-foot.on{display:block}
.theme-light .sb-foot{color:#0E1726}

/* ---------- PANELS (full/intro/result) ---------- */
.center{left:50%;top:50%;transform:translate(-50%,-50%) scale(var(--u))}
.center:not(.on){transform:translate(-50%,-46%) scale(var(--u))}
.panel{background:var(--bg);border-radius:22px;box-shadow:var(--shadow);overflow:hidden;border-bottom:6px solid var(--accent)}
.ptitle{padding:16px 28px;background:var(--bg2);text-align:center}
.ptitle .t1{font-size:32px;font-weight:800}
.ptitle .t2{font-size:22px;color:var(--muted);margin-top:4px}
#full table{border-collapse:collapse;min-width:1100px}
#full td{padding:14px 18px;font-size:40px;font-weight:800;text-align:center}
#full td.n{text-align:left;min-width:520px}
#full td.n .pl{display:block;font-size:22px;font-weight:600;color:var(--muted)}
#full tr+tr td{border-top:1px solid var(--bg2)}
#full th{font-size:20px;color:var(--muted);padding:10px 18px;font-weight:700}
#full td.p{background:var(--accent);color:#111;min-width:120px}
#full td.s{color:var(--muted);min-width:80px}
#full td.s.win{color:var(--fg)}
#full .bar{display:inline-block;width:14px;height:44px;border-radius:4px;vertical-align:middle;margin-right:16px}
#full .srv{display:inline-block;width:16px;height:16px;border-radius:50%;background:var(--accent);margin-left:14px;vertical-align:middle;opacity:0}
#full .srv.on{opacity:1}
#intro .teams{display:flex;align-items:flex-start;gap:40px;padding:36px 48px}
#intro .vs{align-self:center}
#intro .team{width:560px;text-align:center}
#intro .team img{width:180px;height:180px;object-fit:contain;display:none;margin:0 auto 14px}
#intro .team .n{font-size:52px;font-weight:900;padding:10px 0;border-bottom:8px solid}
#intro .team .pl{font-size:28px;color:var(--muted);margin-top:12px;min-height:34px}
#intro .vs{font-size:64px;font-weight:900;color:var(--accent)}
#result .body{padding:34px 60px;text-align:center;min-width:900px}
#result .lbl{font-size:26px;color:var(--muted);letter-spacing:3px;font-weight:800}
#result .w{font-size:72px;font-weight:900;margin:10px 0}
#result .sets{font-size:36px;font-weight:800;color:var(--muted)}
#result .sets b{color:var(--fg)}

/* ---------- BANNER / TICKER ---------- */
#banner{position:absolute;left:50%;top:150px;transform:translate(-50%,-30px) scale(var(--u));opacity:0;transition:all .35s ease;pointer-events:none}
#banner.on{opacity:1;transform:translate(-50%,0) scale(var(--u))}
#banner span{display:block;background:var(--accent);color:#111;font-size:46px;font-weight:900;padding:16px 46px;border-radius:16px;box-shadow:0 12px 30px rgba(0,0,0,.45);letter-spacing:2px;white-space:nowrap}
#ticker{position:absolute;left:0;right:0;bottom:0;height:64px;background:var(--bg);border-top:4px solid var(--accent);overflow:hidden;opacity:0;transition:opacity .35s;color:var(--fg)}
#ticker.on{opacity:1}
#ticker .track{position:absolute;top:0;bottom:0;display:flex;align-items:center;white-space:nowrap;font-size:30px;font-weight:700;will-change:transform;left:100%}
#ticker.on .track{animation:tick var(--dur,30s) linear infinite}
@keyframes tick{from{transform:translateX(0)}to{transform:translateX(calc(-100% - 1920px))}}
#conn{position:absolute;right:10px;bottom:10px;width:12px;height:12px;border-radius:50%;background:#FF5A5F;opacity:0;transition:opacity .3s}
#conn.on{opacity:.9}
</style>
</head>
<body>
<div id="stage" class="theme-dark">
  <div id="scorebar" class="scene">
    <div class="box">
      <div class="sb-head" id="sbHead"><span class="t" id="sbTitle"></span><span class="clock num" id="sbClock"></span></div>
      <div class="sb-row" id="rowA"><i class="sb-color"></i><img class="sb-logo" alt=""><span class="sb-name"></span><span class="sb-serve"><i></i></span><span class="sb-sets"></span><span class="sb-games num"></span><span class="sb-pts num"><span></span></span></div>
      <div class="sb-row" id="rowB"><i class="sb-color"></i><img class="sb-logo" alt=""><span class="sb-name"></span><span class="sb-serve"><i></i></span><span class="sb-sets"></span><span class="sb-games num"></span><span class="sb-pts num"><span></span></span></div>
      <div class="sb-foot" id="sbFoot"></div>
    </div>
  </div>
  <div id="full" class="scene center"><div class="panel">
    <div class="ptitle"><div class="t1" id="fTitle"></div><div class="t2" id="fSub"></div></div>
    <table><thead><tr id="fHead"></tr></thead><tbody id="fBody"></tbody></table>
  </div></div>
  <div id="intro" class="scene center"><div class="panel">
    <div class="ptitle"><div class="t1" id="iTitle"></div><div class="t2" id="iSub"></div></div>
    <div class="teams">
      <div class="team" id="iA"><img alt=""><div class="n"></div><div class="pl"></div></div>
      <div class="vs">VS</div>
      <div class="team" id="iB"><img alt=""><div class="n"></div><div class="pl"></div></div>
    </div>
  </div></div>
  <div id="result" class="scene center"><div class="panel">
    <div class="ptitle"><div class="t1" id="rTitle"></div><div class="t2" id="rSub"></div></div>
    <div class="body"><div class="lbl" id="rLbl">KẾT QUẢ</div><div class="w" id="rWin"></div><div class="sets num" id="rSets"></div></div>
  </div></div>
  <div id="banner"><span id="bannerText"></span></div>
  <div id="ticker"><div class="track"><span id="tickerText"></span></div></div>
  <div id="conn"></div>
</div>
<script>
(function(){
'use strict';
var params=new URLSearchParams(location.search);
var ov={scene:params.get('scene'),theme:params.get('theme'),pos:params.get('pos'),scale:parseFloat(params.get('scale'))};
var stage=document.getElementById('stage');
var state=null, offset=0, es=null, lastSeen=0;
var $=function(id){return document.getElementById(id);};

function fit(){var k=Math.min(window.innerWidth/1920,window.innerHeight/1080)||1;stage.style.transform='scale('+k+')';}
window.addEventListener('resize',fit);fit();

function setText(el,v){if(el.textContent!==v)el.textContent=v;}
function setNum(el,v){if(el.textContent!==v){el.textContent=v;el.classList.remove('bump');void el.offsetWidth;el.classList.add('bump');}}
function teamOf(id){return id==='A'?state.teamA:state.teamB;}
function now(){return Date.now()+offset;}
function fmt(ms){var t=Math.max(0,Math.floor(ms/1000)),h=Math.floor(t/3600),m=Math.floor(t%3600/60),s=t%60;var p=function(x){return(x<10?'0':'')+x;};return(h?h+':'+p(m):p(m))+':'+p(s);}
function logoSrc(t){return t.logoId?'/api/score/logo/'+encodeURIComponent(t.logoId):'';}
function setImg(img,src){if(src){if(img.getAttribute('src')!==src)img.setAttribute('src',src);img.style.display='block';}else{img.removeAttribute('src');img.style.display='none';}}
function titleLine(){var m=state.match||{};return m.tournament||'';}
function subLine(){var m=state.match||{};return [m.round,m.court].filter(Boolean).join(' · ');}

function apply(s){
  if(!s||typeof s.rev!=='number')return;
  if(state&&s.epoch===state.epoch&&s.rev<state.rev)return;
  if(typeof s.serverNowMs==='number')offset=s.serverNowMs-Date.now();
  state=s;render();
}

function render(){
  var s=state, o=s.overlay;
  var theme=['dark','light','glass'].indexOf(ov.theme)>=0?ov.theme:o.theme;
  stage.className='theme-'+theme;
  stage.style.setProperty('--accent',o.accent||'#FFC107');
  var scale=(ov.scale>=0.5&&ov.scale<=2)?ov.scale:(o.scale||1);
  stage.style.setProperty('--u',scale);
  // "Ẩn overlay" trên app/trang điều khiển thắng cả tham số ?scene= của OBS.
  var scene=o.visible===false?'hidden':(ov.scene||o.scene);
  ['scorebar','full','intro','result'].forEach(function(id){$(id).classList.toggle('on',scene===id);});
  renderScorebar(ov.pos||o.position);
  renderFull();renderIntro();renderResult();
  // Thanh tỉ số ở trên giữa thì đưa thông báo xuống dưới để không che nhau.
  var p=ov.pos||o.position;
  $('banner').style.top=(scene==='scorebar'&&p==='tc')?'auto':'150px';
  $('banner').style.bottom=(scene==='scorebar'&&p==='tc')?'150px':'auto';
  renderBanner(scene);renderTicker(scene);
  tickClock();
}

function rowsOrder(){return state.sidesSwapped?['B','A']:['A','B'];}

function renderScorebar(pos){
  var s=state, o=s.overlay, tennis=s.sport==='tennis', el=$('scorebar');
  var m=48, st=el.style;
  st.left=st.right=st.top=st.bottom='';st.transform='';
  var v=pos.charAt(0)==='b'?'bottom':'top', h=pos.charAt(1);
  var tk=o.ticker||{}, tickerOn=tk.enabled&&!!tk.text;
  // Chừa chỗ cho chữ chạy khi thanh tỉ số nằm phía dưới.
  st[v]=(v==='bottom'&&tickerOn?m+72:m)+'px';
  if(h==='l')st.left=m+'px';else if(h==='r')st.right=m+'px';else{st.left='50%';st.transform='translateX(-50%)';}
  var head=$('sbHead');
  var title=o.show.tournament?[titleLine(),subLine()].filter(Boolean).join(' · '):'';
  setText($('sbTitle'),title);
  head.style.display=(title||o.show.timer)?'flex':'none';
  $('sbClock').style.display=o.show.timer?'':'none';
  var order=rowsOrder();
  var box=el.querySelector('.box');
  var rA=$('rowA'), rB=$('rowB');
  if(order[0]==='B'&&rB.nextElementSibling!==rA)box.insertBefore(rB,rA);
  if(order[0]==='A'&&rA.nextElementSibling!==rB)box.insertBefore(rA,rB);
  ['A','B'].forEach(function(id){
    var t=teamOf(id), low=id.toLowerCase(), row=$('row'+id);
    row.querySelector('.sb-color').style.background=t.color;
    setImg(row.querySelector('.sb-logo'),logoSrc(t));
    setText(row.querySelector('.sb-name'),t.name);
    row.querySelector('.sb-serve').classList.toggle('on',o.show.serve&&s.serving===id&&s.status!=='finished');
    row.querySelector('.sb-serve').style.display=o.show.serve?'':'none';
    var sets=row.querySelector('.sb-sets');sets.textContent='';
    if(o.show.sets){s.sets.forEach(function(x){var sp=document.createElement('span');sp.className='num'+(x[low]>x[low==='a'?'b':'a']?' win':'');sp.textContent=x.synthetic?'–':x[low];sets.appendChild(sp);});}
    var games=row.querySelector('.sb-games');games.style.display=tennis?'flex':'none';setText(games,String(s.games[low]));
    setNum(row.querySelector('.sb-pts span'),s.status==='finished'?String(s.setsWon[low]):s.display[low]);
  });
  var foot=$('sbFoot'), kind=s.display.kind, txt='';
  if(s.status==='finished'){txt=s.winner?(teamOf(s.winner).short+' THẮNG'):'KẾT THÚC';}
  else if(kind==='deuce')txt='DEUCE';
  else if(kind==='advantage')txt='LỢI THẾ '+teamOf(s.display.advantage).short;
  else if(kind==='tiebreak')txt='TIE-BREAK';
  else if(kind==='sideout'&&s.rules.doubles)txt=s.display.callout;
  setText(foot,txt);foot.classList.toggle('on',!!txt);
}

function renderFull(){
  var s=state, tennis=s.sport==='tennis';
  setText($('fTitle'),titleLine()||'BẢNG TỈ SỐ');
  setText($('fSub'),[subLine(),s.status==='finished'?'Hết trận':('Set '+s.currentSet)].filter(Boolean).join(' · '));
  var cols=Math.max(s.rules.bestOf,s.sets.length);
  var head=$('fHead');head.textContent='';
  var th=function(t){var e=document.createElement('th');e.textContent=t;head.appendChild(e);};
  th('');for(var i=0;i<cols;i++)th('SET '+(i+1));th('ĐIỂM');
  var body=$('fBody');body.textContent='';
  rowsOrder().forEach(function(id){
    var t=teamOf(id), low=id.toLowerCase(), other=low==='a'?'b':'a', tr=document.createElement('tr');
    var n=document.createElement('td');n.className='n';
    var bar=document.createElement('span');bar.className='bar';bar.style.background=t.color;n.appendChild(bar);
    n.appendChild(document.createTextNode(t.name));
    var srv=document.createElement('span');srv.className='srv'+(s.serving===id&&s.status!=='finished'?' on':'');n.appendChild(srv);
    if(t.players&&t.players.length){var pl=document.createElement('span');pl.className='pl';pl.textContent=t.players.join(' · ');n.appendChild(pl);}
    tr.appendChild(n);
    for(var i=0;i<cols;i++){
      var td=document.createElement('td');td.className='s num';
      var x=s.sets[i];
      if(x){td.textContent=x.synthetic?'–':String(x[low]);if(x[low]>x[other])td.className+=' win';}
      else if(i===s.sets.length&&s.status!=='finished'&&tennis){td.textContent=String(s.games[low]);td.className+=' win';}
      else td.textContent='–';
      tr.appendChild(td);
    }
    var p=document.createElement('td');p.className='p num';p.textContent=s.status==='finished'?String(s.setsWon[low]):s.display[low];tr.appendChild(p);
    body.appendChild(tr);
  });
}

function renderIntro(){
  var s=state;
  setText($('iTitle'),titleLine()||'TRẬN ĐẤU');
  setText($('iSub'),subLine());
  ['A','B'].forEach(function(id){
    var t=teamOf(id), box=$('i'+id);
    var img=box.querySelector('img');
    setImg(img,logoSrc(t));
    // Giữ chỗ logo cho đội không có logo để hai bên thẳng hàng.
    if(!t.logoId&&(s.teamA.logoId||s.teamB.logoId)){img.style.display='block';img.style.visibility='hidden';}
    else img.style.visibility='';
    var n=box.querySelector('.n');setText(n,t.name);n.style.borderColor=t.color;
    setText(box.querySelector('.pl'),(t.players||[]).join(' · '));
  });
}

function renderResult(){
  var s=state;
  setText($('rTitle'),titleLine()||'KẾT QUẢ TRẬN ĐẤU');
  setText($('rSub'),subLine());
  setText($('rLbl'),s.status==='finished'?'CHIẾN THẮNG':'TỈ SỐ HIỆN TẠI');
  var leader=s.winner||(s.setsWon.a===s.setsWon.b?null:(s.setsWon.a>s.setsWon.b?'A':'B'));
  setText($('rWin'),leader?teamOf(leader).name:(teamOf('A').short+' – '+teamOf('B').short));
  var box=$('rSets');box.textContent='';
  var b=document.createElement('b');b.textContent=s.setsWon.a+' – '+s.setsWon.b;box.appendChild(b);
  if(s.sets.length){box.appendChild(document.createTextNode('   ('+s.sets.map(function(x){var tb=(x.tbA!=null&&x.tbB!=null)?('⁽'+Math.min(x.tbA,x.tbB)+'⁾'):'';return x.synthetic?'–':(x.a+'-'+x.b+tb);}).join(', ')+')'));}
}

function renderBanner(scene){
  var o=state.overlay, b=o.banner||{};
  var visible=scene!=='hidden'&&!!b.text&&(!b.untilMs||now()<b.untilMs);
  setText($('bannerText'),b.text||'');
  $('banner').classList.toggle('on',visible);
}

var tickerSig='';
function renderTicker(scene){
  var t=state.overlay.ticker||{}, on=scene!=='hidden'&&t.enabled&&!!t.text;
  var el=$('ticker');
  var sig=(t.text||'')+'|'+t.speed;
  if(sig!==tickerSig){tickerSig=sig;setText($('tickerText'),t.text||'');
    var pxPerSec=[0,90,150,230][t.speed||2]||150;
    var dist=1920+(t.text||'').length*18;
    el.style.setProperty('--dur',Math.max(8,dist/pxPerSec).toFixed(1)+'s');
    var track=el.querySelector('.track');track.style.animation='none';void track.offsetWidth;track.style.animation='';
  }
  el.classList.toggle('on',on);
}

function tickClock(){
  if(!state)return;
  var tm=state.timer;var ms=tm.accumulatedMs+(tm.running?Math.max(0,now()-tm.startedAtMs):0);
  setText($('sbClock'),fmt(ms));
  var b=state.overlay.banner||{};
  if(b.untilMs&&$('banner').classList.contains('on')&&now()>=b.untilMs)$('banner').classList.remove('on');
}
setInterval(tickClock,500);

function setConn(on){$('conn').classList.toggle('on',!on&&params.get('dot')!=='0'&&params.get('preview')!=='1');}
function connect(){
  if(es){try{es.close();}catch(e){}}
  es=new EventSource('/api/score/events');
  es.addEventListener('state',function(e){lastSeen=Date.now();setConn(true);try{apply(JSON.parse(e.data));}catch(err){}});
  es.addEventListener('ping',function(){lastSeen=Date.now();setConn(true);});
  es.onerror=function(){setConn(false);};
}
function poll(){return fetch('/api/score',{cache:'no-store'}).then(function(r){return r.json();}).then(apply).catch(function(){});}
setInterval(function(){if(Date.now()-lastSeen>25000){setConn(false);connect();poll();}},5000);
connect();poll();
})();
</script>
</body>
</html>
''';
