// Metadata-only report. Does not alter application code or character assets.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const appearances = [
  ['crf_skn_002_0001_01', '常服·坐姿'],
  ['crf_skn_002_0001_99', '常服·站姿'],
  ['crf_skn_002_0002_01', '夏日泳装·黄色'],
  ['crf_skn_002_0003_01', '夏日泳装·黑色'],
  ['crf_skn_002_0004_01', '休闲 T 恤'],
  ['crf_skn_002_0005_01', '夏日泳装·蓝白短裤'],
].map(([id, label]) => {
  const relative = `assets/character/ryza/${id}/${id}_gesture.json`;
  const bytes = fs.readFileSync(path.join(root, relative));
  return { id, label, relative, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), data: JSON.parse(bytes) };
});
const seated = appearances[0].data.emotionalGesture;
const standing = appearances[1].data.emotionalGesture;
for (const appearance of appearances.filter(a => a.id !== appearances[1].id)) {
  assert.deepEqual(appearance.data.emotionalGesture.MotionGroups, seated.MotionGroups);
}

const description = Object.fromEntries(`
grp_b_01|转动肩膀|放松肩部、久坐伸展
grp_b_02|双手叠放|安静倾听、拘谨等待
grp_b_03|双手叉腰|自信展示、佯装不满
grp_b_05|抱臂|思考、质疑、有主见地回应
grp_b_07|双手放在胸前|真诚回应、惊喜、珍惜
grp_b_12|左右伸展／伸懒腰|疲惫后舒展、放松
grp_b_13|双手放在大腿内侧|收敛、拘谨坐姿
grp_c_01|双脚晃荡|轻松等待、活泼闲聊
grp_c_02|改变腿部角度／放松腿姿|长时间坐着时调整姿势
grp_c_03|膝盖开合|坐姿细节，避免频繁触发
grp_c_04|调整大腿高度|身体重心与坐姿调整
grp_c_05|盘腿姿态|切换至适配的盘腿表现
grp_eh_10|身体轻晃待机|低强度闲聊、等待
grp_eh_20|身体倾斜待机|倾听、自然换重心
grp_eh_30|身体上下弹动|轻快回应；需控制频率
grp_eh_40|向后倾斜|拉开距离、后仰反应
grp_eh_50|向左倾斜|侧身倾听
grp_eh_60|向右倾斜|侧身倾听
grp_eh_70|向前倾斜|靠近倾听、表示兴趣
grp_fg_016|双手比耶|明确比耶请求、拍照、庆祝
grp_fg_017|双手托腮版本（原注明不使用）|不推荐直接选择
grp_fg_018|耳语姿势|悄悄话、ASMR 场景
grp_fg_019|张开手掌触碰|伸掌互动；并非一定触到目标
grp_fg_020|“嘘”手势|示意安静、保密
grp_fg_021|双手指向手势|指示、介绍或说明
grp_fg_022|双手叠放在大腿上|安静、礼貌地坐着
grp_fg_023|双手抱臂组合|思考、质疑
grp_fg_024|双手拍手|鼓励、祝贺、明确拍手请求
grp_fg_025|双手放在沙发上|放松支撑、待机
grp_fg_026|双手放在大腿上|自然倾听、安静回应
grp_fg_027|盘腿专用双手|仅配合允许的盘腿姿势
grp_fg_028|展示双掌、挥手告别|告别、双手挥动
grp_fg_029|展示双掌、慌张摆动|惊慌、不知所措
grp_fg_030|双手握拳打气|庆祝、鼓劲
grp_fg_031|双手向前伸出／拥抱姿势|邀请拥抱、迎接；不代表完成接触
grp_fg_032|双掌示意“等一下”|制止、请求暂停
grp_fg_033|双手挥手问候|问候、告别
grp_i_01|左脚晃荡|轻松待机
grp_i_02|活动左侧盘腿|盘腿姿态的小调整
grp_j_01|右脚晃荡|轻松待机
grp_j_02|活动右侧盘腿|盘腿姿态的小调整
`.trim().split('\n').map(line => { const [id, zh, use] = line.split('|'); return [id, { zh, use }]; }));
const handDescription = Object.fromEntries(`
01|通常位置|放松、自然待机
02|放在腰间|单手叉腰、自信回应
06|放在下巴附近|思考、倾听；不是挠头
07|放在嘴边|犹豫、轻声回应
08|放在眼睛附近|眼部动作；不能只凭标签认定擦泪
09|放在太阳穴附近|思索、困扰
10|放在头部|触头动作；不能保证是挠头
11|遮住嘴部|害羞、轻笑
15|抱枕相关动作|仅在抱枕、姿态适配时使用
16|比耶|单手比耶、拍照
17|托腮|放松倾听、俏皮互动
18|耳语配套姿势|悄悄话
19|张开手掌触碰|伸掌互动
20|“嘘”手势|安静、保密
21|指向手势|介绍、指示
22|大腿叠手的单手片段（原注明不使用）|不推荐单独选择
23|抱臂的单手片段（原注明不使用）|不推荐单独选择
24|拍手的单手片段（原注明不使用）|不推荐单独选择
25|放在沙发上|放松支撑
26|放在大腿上|自然倾听
27|盘腿专用手位|仅配合盘腿姿态
28|展示手掌、挥手告别|单手告别
29|展示手掌、慌张摆动|慌张、惊讶
30|握拳打气|鼓励、兴奋
31|向用户方向伸出|邀请、迎接
32|掌心示意“等一下”|制止、暂停
33|抬至胸口高度问候|轻幅问候
`.trim().split('\n').map(line => { const [id, zh, use] = line.split('|'); return [id, { zh, use }]; }));
for (const side of [1, 2]) {
  for (const [suffix, value] of Object.entries(handDescription)) {
    description[`grp_fg_${side}${suffix}`] = { zh: `${side === 1 ? '左手' : '右手'}${value.zh}`, use: value.use };
  }
}
description.grp_fg_118 = { zh: '左手放在胸前（耳语的配套手位）', use: '悄悄话、配合另一只手的耳语姿势' };
description.grp_fg_217 = { zh: '右手放在沙发上（托腮的配套支撑手）', use: '配合左手托腮；右手本身不是托腮' };

const standingDescription = Object.fromEntries(`
grp_fg_000|双臂自然默认姿势|恢复站姿手位
grp_fg_001|双手叉腰|自信、不服气、展示成果
grp_fg_002|双手抱臂|思考、质疑
grp_fg_003|双手轻摆／挥动|问候、轻快回应；不是坐姿握拳打气
grp_fg_004|双手在背后交握|拘谨、害羞、轻松等待
grp_fg_f_002|左手叉腰|自信、强调
grp_fg_f_003|左手放到右臂|抱臂的左侧构成
grp_fg_f_004|左手轻摆|单手问候
grp_fg_f_005|左手放到身后|含蓄、放松
grp_fg_g_002|右手叉腰|自信、强调
grp_fg_g_003|右手放到左臂|抱臂的右侧构成
grp_fg_g_004|右手轻摆|单手问候
grp_fg_g_005|右手放到身后|含蓄、放松
grp_fg_g_006|右手呈猫爪状轻轻抬起|俏皮、轻微打趣
grp_fg_g_007|右手向前伸出|邀请、递手、说明；不是双手拥抱
grp_fg_g_008|右手耳语姿势|悄悄话；不等于遮脸
grp_fg_g_009|右手触碰脸颊|触脸、思索；不保证是挠脸
`.trim().split('\n').map(line => { const [id, zh, use] = line.split('|'); return [id, { zh, use }]; }));
const eZh = ['左右摇晃', '前后摇晃', '向左倾斜', '向右倾斜', '前倾', '后仰'];
const hZh = ['上下运动', '上下运动（两循环版本）', '左右运动', '左右运动（两循环版本）', '扭捏小动作', '摆腰'];
for (let e = 1; e <= 6; e++) for (let h = 1; h <= 6; h++) {
  standingDescription[`grp_eh_${e}${h}`] = {
    zh: `${eZh[e - 1]}＋${hZh[h - 1]}`,
    use: h === 5 ? '局促、害羞时的身体层表现' : e === 5 ? '感兴趣、靠近倾听的身体层表现' : e === 6 ? '意外、后退反应的身体层表现' : '待机或对话的身体层变化，需控制幅度和频率',
  };
}
const gazeZh = Object.fromEntries(`
A1|思考、回忆
A2|后仰、惊讶
A3|陷入思考、低落
A4|缩起身体
A5|难以启齿、尴尬
A6|把视线移向别处
A7|彻底转开、拒绝
B1|抬眼看用户
B2|抬下巴、俯视
B3|脸转开但看着用户
B4|闹别扭、撒娇
B5|表现出兴趣
C1|观察情况
C2|无语、厌烦
C3|垂下眼睛、尴尬
D1|自然注视
D2|被气势压住
E1|东张西望
E2|眼神游移
E3|来回比较
E4|环顾四周
`.trim().split('\n').map(line => line.split('|')));
const translatedValues = {
  '動かない': '不动', '傾けない': '不倾斜', '逆方向': '反方向', '同方向': '同方向',
  '追従（弱）': '弱跟随', '追従（中）': '中等跟随', '追従（強）': '强跟随',
  '指定方向': '指定方向', 'ユーザー注視': '注视用户', 'なし': '无', '上': '上', '下': '下',
  '右': '右', '左': '左', '斜め上': '斜上方', '斜め下': '斜下方', '正面': '正前方',
};
const tr = value => translatedValues[value] || value;
const groupsOf = eg => {
  const groups = new Map();
  eg.MotionGroups.forEach((row, index) => {
    if (!groups.has(row.GroupId)) groups.set(row.GroupId, []);
    groups.get(row.GroupId).push({ ...row, sourceRow: index + 1 });
  });
  return groups;
};
const seatedGroups = groupsOf(seated), standingGroups = groupsOf(standing);
assert.equal(seatedGroups.size, 95);
assert.equal(standingGroups.size, 53);
for (const id of seatedGroups.keys()) assert.ok(description[id], `Missing seated description ${id}`);
for (const id of standingGroups.keys()) assert.ok(standingDescription[id], `Missing standing description ${id}`);
for (const g of seated.GesturePatternDefs) assert.ok(gazeZh[g.patternId]);
const esc = value => String(value ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
const code = value => '`' + value + '`';
const lines = [];
const p = (...text) => lines.push(...text.flatMap(value => /^#{1,6} /.test(value) ? [value, ''] : [value]), '');
const table = (header, rows) => p('| ' + header.join(' | ') + ' |', '| ' + header.map(() => '---').join(' | ') + ' |', ...rows.map(row => '| ' + row.map(esc).join(' | ') + ' |'));
const link = relative => '../' + relative.replaceAll('\\', '/');
const baseWeights = eg => Object.fromEntries(Object.entries(eg.EmotionProfilesV4).map(([key, value]) => {
  const n = value.intensityProfiles.normal;
  return [key, n.armGroupWeights || n.armGroupWeightsByPoseType?.[''] || {}];
}));
const topFaces = (eg, id) => Object.entries(baseWeights(eg)).map(([face, weights]) => [face, Number(weights[id] || 0)]).filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([face, weight]) => `${face}=${weight}`).join('；') || '基础手臂权重未给正值';

const auditDate = new Date().toLocaleDateString('sv-SE', {
  timeZone: 'Asia/Shanghai',
});
p('# 莱莎动作组完整解析', `核对日期：${auditDate}。范围：当前 \`ryza_chat_mvp\` 实际配置的六套莱莎资源与当前 Dart 播放代码。`);
p('这是静态资源和代码解析报告，不是逐帧视觉验收。中文动作名称译自资源 `Label`，使用场景是分析建议，不是现有触发条件，也没有添加用户输入关键词匹配。未修改运行时代码、提示词或资源。');
p('## 1. 总量与目录层级');
table(['外观（应用内名称）', '资源 ID', 'MotionGroups 行数', '唯一动作组'], appearances.map(a => [a.label, code(a.id), a.data.emotionalGesture.MotionGroups.length, groupsOf(a.data.emotionalGesture).size]));
p('五套坐姿服装的 `MotionGroups` 数组逐字段完全相同：每套 140 条变体，归入 95 个 GroupId。站姿有 53 条／53 组。按坐姿与站姿目录区分，合计 **148 个动作组、193 条变体定义**；六个文件直接相加是 753 行，包含服装间重复，不能算成 753 种动作。');
p('`[action:think]` 是 LLM 意图标签；`grp_fg_106` 是组合动作组；`motion_add_F_027_active` 是 Spine 动画片段；`A1` 是视线／头身运动模式。四者不能互相当成标签使用。当前有 12 个 action 枚举（其中一个是 none）、9 个 face 枚举，而不是 148 个模型可直接调用标签。');
table(['坐姿类别', '含义', '唯一组数', '变体行数'], [['B','肩部／双臂整体动作',7,9],['C','腿部整体动作',5,11],['E','躯干倾斜与晃动',7,11],['FG','左右手臂组合',72,101],['I','左腿动作',2,4],['J','右腿动作',2,4]]);
p('站姿由 36 个 EH 身体组合与 17 个 FG 手臂组合组成。F/G 在坐姿标记中分别对应左／右手臂；单手动作通常也带另一只手的支撑／休息片段，并非只有一条动画。站姿 EH 是 6 个 E 分量与 6 个 H 分量的配对。');

function overview(title, eg, grouped, descriptions) {
  p(title, '“场景建议”仅作语义分析。原文含“使わない”的组会明确标出；其存在不代表应在对话中使用。全部变体、原始名称和限制见后面的逐组明细。');
  table(['GroupId', '中文动作解释', '变体数', '场景建议'], [...grouped].map(([id, rows]) => [code(id), descriptions[id].zh, rows.length, descriptions[id].use]));
}
overview('## 2. 坐姿 95 组动作清单', seated, seatedGroups, description);
overview('## 3. 站姿 53 组动作清单', standing, standingGroups, standingDescription);
p('注意：站姿 `grp_fg_003` 是双手轻摆，坐姿 `grp_fg_030` 是双手握拳打气；站姿的 F/G 编号也不能套用坐姿的编号含义。需要用“资源外观＋GroupId”一起定位。');

p('## 4. 21 个视线、头部与身体微动作模式', '这些是 `GesturePatternDefs`，不属于 MotionGroups，也不是当前可直接输出的 `[action:A1]` 标签。表中的脸部运动指头脸朝向，不是 face 表情贴图。');
table(['模式', '中文含义', '眼睛', '脸部朝向', '身体移动', '身体倾斜', '方向／轨迹'], seated.GesturePatternDefs.map(g => [code(g.patternId), gazeZh[g.patternId], tr(g.eyeMovement), tr(g.faceMovement), tr(g.bodyMovement), tr(g.bodyTilt), `${(g.directions || []).map(tr).join('、')}；${g.route}；${g.points} 点`]));
p('这套配置能表达“头稍转开但眼睛仍看着用户”“先移开视线再跟随身体”等差别。自然感来自这些注视模式、面部组合和有意义的手势共同工作，不是连续播放大量主动作。');
const attitudeNames = {talk_low:'说话／兴趣低',talk_mid:'说话／普通',talk_high:'说话／兴趣高',idle_low:'等待／兴趣低',idle_mid:'等待／普通',idle_high:'等待／兴趣高',agree:'赞同后',deny:'否定后',question:'提问后'};
p('### 4.1 全部 57 条态度调度记录', '每条把视线模式、大小、速度、停留、重复范围和可选 one-shot 关联起来；权重是候选间的相对权重。下表来自常服坐姿，文件之间的行为配置可能不同，不能因为 MotionGroups 相同就断言整个 gesture 相同。');
table(['状态', '模式及含义', '大小／速度／停留', '重复次数', '权重', '一次性动画'], seated.AttitudePatterns.map(a => [attitudeNames[a.attitude] || a.attitude, `${a.patternId} ${gazeZh[a.patternId] || a.description}`, `${a.size}／${a.moveSpeed}／${a.dwell}`, `${a.repeatMin}–${a.repeatMax}`, a.weight, a.oneShotAnimation ? code(a.oneShotAnimation) : '无']));

p('## 5. 不在 MotionGroups 中的其他动作');
p('### 5.1 12 个一次性反馈动画', '当前菜单的 `motionDisplayName` 将 D001–D002 标作赞同、D003–D008 标作否定、D009–D012 标作提问。这是代码分类，不能仅凭编号断言具体点头幅度或骨骼运动。`AttitudePatterns` 实际引用的是其中 8 个片段。');
table(['动画', '当前菜单分类', '资源态度表的使用位置'], Array.from({length:12}, (_, i) => {
  const n = i + 1, name = `motion_oneshot_D_${String(n).padStart(3,'0')}_active`;
  return [code(name), n <= 2 ? '赞同' : n <= 8 ? '否定' : '提问', [...new Set(seated.AttitudePatterns.filter(a => a.oneShotAnimation === name).map(a => attitudeNames[a.attitude]))].join('、') || '本次常服态度表未引用'];
}));
p('### 5.2 7 个触摸反馈片段');
const parts = {arm_l:'左臂',arm_r:'右臂',body:'身体',breast:'胸部',head:'头部',weast:'腰部（原键名 weast）'};
table(['部位', '动画'], seated.TapReactions.map(t => [parts[t.PartName] || t.PartName, code(t.OverlayID)]));
p('### 5.3 基础姿态', '基础姿态使用 `motion_A_*_idle`；它是叠加动作的底座，不计入以上 148 组。常服坐姿配置了 20 个 idle 候选，站姿 7 个，新加入的四套坐姿服装各列出 3 个。姿态类型转换表的 36／49 行是转移权重矩阵，不是 36／49 个新动作。');
table(['目录', 'PoseTypeSets 的唯一节点'], [['坐姿', [...new Set(seated.PoseTypeSets.flatMap(x => [x.previousId,x.newId]))].map(code).join('、')], ['站姿', [...new Set(standing.PoseTypeSets.flatMap(x => [x.previousId,x.newId]))].map(code).join('、')]]);
p('普通坐与盘腿分别是 `sitting_normal`、`sitting_agura`。资源 SittingSets 的跨姿态权重为 0，自保持权重为 99999，不能理解为会自动随机盘腿。');

p('## 6. 目前模型标签实际覆盖的动作');
const perf = fs.readFileSync(path.join(root, 'lib/src/character_performance.dart'), 'utf8');
function readPlans(marker) {
  const start = perf.indexOf(`const ${marker}`), end = perf.indexOf('\n};', start);
  assert.ok(start >= 0 && end > start);
  return Object.fromEntries([...perf.slice(start,end).matchAll(/CharacterAction\.(\w+): CharacterActionPlan\(([\s\S]*?)\),/g)].map(m => [m[1], { ids:[...m[2].matchAll(/'(grp_[^']+)'/g)].map(x=>x[1]), fallback: /oneShotFallback:\s*'([^']+)'/.exec(m[2])?.[1] || '' }]));
}
const seatedPlans = readPlans('_seatedActionPlans'), standingPlans = readPlans('_standingActionPlans');
const tags = /enum CharacterAction\s*\{([^}]+)\}/.exec(perf)[1].split(',').map(x=>x.trim()).filter(Boolean);
const describePlan = (plan, descriptions) => plan ? [...plan.ids.map(id => `${code(id)} ${descriptions[id]?.zh || '需核对'}`), ...(plan.fallback ? [`回退 ${code(plan.fallback)}`] : [])].join('<br>') : '不发起新主动作';
table(['LLM action 标签', '坐姿计划', '站姿计划'], tags.map(tag => [code(`[action:${tag}]`), describePlan(seatedPlans[tag],description), describePlan(standingPlans[tag],standingDescription)]));
const coverage = plans => new Set(Object.values(plans).flatMap(p=>p.ids)).size;
p(`静态 action 计划只引用坐姿 **${coverage(seatedPlans)}／95** 组、站姿 **${coverage(standingPlans)}／53** 组，另有 one-shot 回退。这个数字是“语义映射直接覆盖数”，不是全应用播放过的组数：手动菜单、环境动作还有独立入口。`);
const positiveGroups = eg => new Set(Object.values(baseWeights(eg)).flatMap(weights => Object.entries(weights).filter(([, w]) => Number(w) > 0).map(([id]) => id))).size;
p(`常服通用 normal 手臂权重在九种表情中取并集，坐姿有 ${positiveGroups(seated)} 个组为正值、站姿有 ${positiveGroups(standing)} 个。当前自动选择还要按实际表情和姿态继续筛选；这不是实际播放计数，也不能套用为其他服装表情配置完全相同的证明。`);
p('主要语义偏差：think 可以选到抱臂，不保证挠头；坐姿 comfort 与 invite 都指向双手前伸／拥抱；站姿 comfort、explain、invite 都使用右手伸出；站姿 shy 的候选包括耳语；坐姿 playful 是双手比耶。表情不同能改变观感，却不能把同一个肢体动画变成另一个精准动作。');
p('还有映射存在却没有选中动作的路径：坐姿 playful 对应的 grp_fg_016 在九种基础情绪权重中都为 0，选择器返回空，且 playful 无回退；坐姿 excited 的 grp_fg_030 也全为 0，通常回退 D002。坐姿 explain 的三个指向组只在部分表情下有正权重，其他表情可退回 D009。站姿 surprised 的 grp_eh_61 也没有正手臂权重，但它有特殊的兼容候选回退路径。');
p('叉腰资源确实存在：坐姿 `grp_b_03`，以及左右单手 `grp_fg_102`／`grp_fg_202`；站姿 `grp_fg_001`，以及 `grp_fg_f_002`／`grp_fg_g_002`。当前 action 枚举没有精确叉腰标签，这些组也不在上述 action 计划里。所以只要求模型“更认真判断”，仍无法可靠地通过当前有限标签表达任意精确动作。');
p('此前加入的 `CharacterPerformancePromptContext` 只有定义和可选形参；当前聊天请求仍未传入真实快照，走 `status=unknown`。本次只是核对现状，没有补接调用。精确动作能力尚未随资源动态提供给模型。');
p('`_executeSemanticAction` 先尝试 `fixedGestureBindingsByAttitude`；当前六套资源的 EmotionProfilesV4 中没有这个字段，原文件是另一处 `AttitudePatterns` 记录。因此该优先分支目前不会接管语义动作选择，仍需走上表计划。两种结构不能因名字相近就认为已经接通。');

p('## 7. 原始字段与当前播放行为');
table(['字段', '资源含义／阅读方式', '当前代码处理'], [
  ['GroupId / VariantIndex','动作组与组内变体','按每行加载；未保存 VariantIndex'],
  ['AnimName_1 / AnimName_2','同组一起播放的片段','检查当前 skeleton 是否有对应名称'],
  ['OccupancyLetters','部位／通道占用，如 FG、EH','转换为应用轨道；不是模型输出标签'],
  ['Alpha1 / Alpha2','每条片段的混合权重','按值传给 Spine；两条都为 0 时没有可见贡献'],
  ['Speed1 / Speed2','片段播放速度','用于 setTimeScale 和预计时长'],
  ['BlendTime','进入／退出混合时间','进入至少 0.28 秒，退出至少 0.30 秒'],
  ['ApplicablePoseIds','允许的基础动画姿态','按当前 idle 检查；空值不额外限制'],
  ['ApplicableSittingIDs','允许的坐姿类型','调用默认按 sitting_normal 检查'],
  ['GroupWeight / VariantWeight','原作者组／变体权重','CharacterMotionGroup 未解析，不能当成已生效的过滤条件'],
  ['RepeatCount','原作者重复设置','未解析；当前主组合以 loop=false 播一次'],
  ['EmotionProfilesV4','表情、姿态与手臂组相对权重','解析 normal 配置；语义动作路径取基础权重，不传 poseType'],
]);
p('资源字段缺省说明与应用行为需要分别理解：`GroupWeight=0` 不是现在菜单一定禁用；“基础表情权重全零”也不代表 skeleton 没有动作。实际选择还受到资源就绪、当前姿态、触摸反应、动作队列、冷却和当前表情影响。');
p('### 7.1 本次发现的明确限制');
const disabled = [...seatedGroups].filter(([, rows]) => rows.some(r=>r.Label.includes('使わない'))).map(([id])=>id);
const invisible = seated.MotionGroups.filter(r => Number(r.Alpha1) === 0 && (!r.AnimName_2 || Number(r.Alpha2) === 0));
const agura = seated.MotionGroups.filter(r => r.ApplicableSittingIDs && !r.ApplicableSittingIDs.split(',').includes('sitting_normal'));
p(`- 坐姿 ${disabled.length} 组注明不使用：${disabled.map(code).join('、')}。当前菜单仍加载，播放校验未按这段备注禁用。`,
  `- ${invisible.map(r=>code(r.GroupId)+' 的 '+code(r.AnimName_1)+' + '+code(r.AnimName_2)).join('；')}：Alpha1 与 Alpha2 都为 0，可能表现为选中后没有可见变化。`,
  `- ${agura.length} 条坐姿变体限制为盘腿，当前默认 sitting_normal 校验无法通过。详细范围见逐组明细。`,
  '- 七个 grp_b_* 的 GroupWeight 都为 0，但当前 Dart 未读取该字段；另有 VariantWeight 为 0 的 E 层条目，也未按该字段排除。',
  '- `_playMotionGroup` 开始时会重置旧的身体动作叠加层；当前实现不等于任意多个 B/C/E/FG 动作能持续自由组合。',
  '- 基础脸部匹配来自权重，缺少正权重时保留当前表情，不保证每个手动动作自动出现专属表情。',
  '- 每个动作组是否真正包含所有骨骼／贴图效果，还需要加载对应 skeleton 逐项播放确认；本报告未进行该视觉验证。');

p('## 8. 完整变体与约束明细', '以下逐项保留原始日文名称、动画全名和参数，便于在菜单、日志与 gesture 中交叉搜索。每个坐姿组只列一次，适用于五套坐姿的相同 MotionGroups；不要把站姿名称套用到坐姿。', '基础表情权重只摘取 normal 的通用 armGroupWeights／ByPoseType 空键前三个正值。这些是相对权重，**不是归一化概率，也不是强制表情**；姿态专属权重可能另有配置。');
let rowCount = 0;
function details(title, eg, groups, dictionary, prefix) {
  p(title);
  for (const [id, rows] of groups) {
    p(`#### ${prefix} ${id} — ${dictionary[id].zh}`, `原标注：${[...new Set(rows.map(r=>r.Label))].map(code).join('；')}。占用：${code(rows[0].OccupancyLetters)}。`, `基础表情权重：${topFaces(eg,id)}。`);
    const restrictions = new Map();
    for (const r of rows) {
      const key = `${r.ApplicablePoseIds}|${r.ApplicableSittingIDs}`;
      if (!restrictions.has(key)) restrictions.set(key, `P${restrictions.size+1}`);
    }
    for (const [key, alias] of restrictions) {
      const [poses, sitting] = key.split('|');
      p(`${alias}：基础姿态 ${poses ? poses.split(',').map(code).join('、') : '未额外限制'}；坐姿类型 ${sitting ? code(sitting) : '未额外限制'}。`);
    }
    table(['原始行／变体', '动画 1', '动画 2', 'Alpha 1/2', 'Speed 1/2', '混合秒', '组／变体权重', '重复', '限制'], rows.map(r => {
      rowCount++;
      return [`${r.sourceRow} / ${r.VariantIndex}`,code(r.AnimName_1), r.AnimName_2 ? code(r.AnimName_2) : '无',`${r.Alpha1 || '空'} / ${r.Alpha2 || '空'}`,`${r.Speed1 || '空'} / ${r.Speed2 || '空'}`,r.BlendTime,`${r.GroupWeight} / ${r.VariantWeight}`,r.RepeatCount,restrictions.get(`${r.ApplicablePoseIds}|${r.ApplicableSittingIDs}`)];
    }));
  }
}
details('### 8.1 坐姿明细',seated,seatedGroups,description,'坐姿');
details('### 8.2 站姿明细',standing,standingGroups,standingDescription,'站姿');
assert.equal(rowCount,193);

p('## 9. 后续改进建议（未实施）', '推荐保留模型语义判断，同时让它看到当前可用的精确动作目录。目录来自现有 MotionGroups 及真实 resolver，先排除不使用、零贡献、不兼容姿态，再提供短中文动作说明。不要把“用户文本含叉腰”写成本地触发条件。', '可以把情绪意图与具体肢体动作分开：如表情是 tease，精确动作选双手叉腰；旁白根据已经选中的动作生成。这样比把叉腰硬塞到 explain 或 playful 更清楚，也不会因为“想表达开心”就总做比耶。', '实施时优先修正真实能力快照接入、精确动作选择入口、权重与禁用过滤、段级幂等及动作完成回执；再调整表情和微动作节奏。不能通过增加动作次数掩盖标签表达不了具体动作的问题。');
p('## 10. 来源与验证');
table(['来源', 'SHA-256'], appearances.map(a=>[`[${a.id}](${link(a.relative)})`, code(a.sha256)]));
p('代码入口：');
p('- [外观、动作组解析与权重](../lib/src/character_appearance.dart)', '- [LLM action 枚举与坐站语义映射](../lib/src/character_performance.dart)', '- [动作校验、播放与聊天请求](../lib/src/chat_screen.dart)', '- [标签分段解析](../lib/src/chat_segments.dart)', '- [表情与动作队列](../lib/src/character_performance_queue.dart)', '- [提示词与可选能力快照](../lib/src/app_controller.dart)');
p('主要执行定位（本次核对行号）：');
table(['阶段','位置'],[['能力快照定义／提示词生成','app_controller.dart:266 / :820'],['实际 LLM 请求（未传 performanceContext）','chat_screen.dart:1535'],['段落与控制标签解析','chat_segments.dart:557 / :590'],['模型输出到表情和动作','chat_screen.dart:1124'],['队列调度／语义选择','chat_screen.dart:1161 / :1192'],['兼容检查／Spine 轨道播放','chat_screen.dart:434 / :444'],['TTS 段落播放前表演','chat_screen.dart:1829'],['菜单列出原始变体行','chat_screen.dart:3625']]);
p('本报告生成时检查了：六个 JSON 可解析、五套坐姿 MotionGroups 一致、95／53 唯一组计数、193 条变体完整输出、148 个组均有中文解释、21 个视线模式均有中文解释；并从当前 character_performance.dart 提取标签计划。未调用 LLM/TTS 服务、未修改 App、未构建或安装 APK、未逐帧查看 148 组动作。', '重新生成：在项目目录运行 `node scripts/export_ryza_motion_catalog.cjs`。中文解释与诊断对应本次源码快照；资源或运行时代码修改后应重新人工核对。输出只有文本报告，不包含图片、音频、模型或骨骼二进制。');
const output = path.join(root, 'docs/RYZA_MOTION_GROUP_CATALOG.md');
fs.writeFileSync(output, lines.join('\n') + '\n', 'utf8');
console.log(JSON.stringify({output, appearances:appearances.length, seatedGroups:seatedGroups.size, standingGroups:standingGroups.size, variantRows:rowCount, gazePatterns:seated.GesturePatternDefs.length, actionCoverage:{seated:coverage(seatedPlans),standing:coverage(standingPlans)}, bytes:fs.statSync(output).size},null,2));
