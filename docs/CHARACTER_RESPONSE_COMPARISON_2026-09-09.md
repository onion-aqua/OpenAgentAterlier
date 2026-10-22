# 对话表情与动作：原版配置和 Demo 对比

检查日期：2026-09-09。范围：当前 `ryza_chat_mvp` 的对话演出链路，以及外层 APK 解包目录中的角色 gesture 配置。本次只进行分析和运行已有测试，没有修改应用动画行为。

## 结论

可以依据本地原版资源重建更接近原设计的对话响应。当前不自然主要来自多个动作调度入口相互叠加、部分原始参数被二次改写，以及大量原配表情组合未被加载；不是缺少动作素材。

不建议继续扩大随机动作池或提高摇头幅度。推荐以原版配置驱动连续表情与头身运动，由 LLM 只指定情绪和语义意图，再由一个调度器选择、保持和结束动作。

外层目录是 APK 解包结果。已找到 `_gesture.json` 和 AOT `lib/arm64-v8a/libapp.so`，没有完整可编辑的原应用 Dart 源码。配置里的 `machines: {idle: idle, talk: talk}` 只是状态名称，不能据此声称已经还原了原版完整状态机或实际时序。

## 现有控制链路

`AppController.buildCharacterPrompt()` 要求 LLM 给每条莱莎台词输出：

```text
莱莎：[语音情绪][face:表情][action:语义动作] 台词
```

`chat_segments.dart` 提取表情与动作。TTS 路径按台词分段，在播放前应用 face/action；非 TTS 路径每收到一次流式增量，就重新解析完整回复。`character_performance.dart` 将语义动作映射到少量固定动作组，`chat_screen.dart` 最终写入 Spine 轨道。

与此同时，随机手势、语音能量触发、眼眉随机切换、眨眼、原始 DriverDefs 适配和额外正弦摇摆都能独立改变角色。

## 有直接证据的问题

| 项目 | 当前 Demo | 影响与建议 |
| --- | --- | --- |
| `action:none` | 解析时忽略 none，但动作标签总数继续增加；流式去重用“最后非 none 动作 + 总数” | `think:1` 后收到 none 会变成 `think:2`，重复旧动作。应按完整台词/标签事件消费一次，none 明确表示本段无动作 |
| 自动手势频率 | 无音频包络讲话时每 1.8–3.8 秒随机一组，待机每 3.8–7.4 秒；有包络时能量越阈后最短 2.4 秒再触发 | 这些不是语义节点。应取消讲话期间的随机整组探索，把音量用于口型，明确语义才触发大手势 |
| 骨骼运动叠加 | 原始 driver 的 yaw/pitch/roll 之后，仍叠加 70% 的自定义正弦层，额外头部旋转限制为 ±18° | 原版目标运动与持续摆动相加。应优先只使用一个连续头身驱动，缺资源时才启用低幅回退 |
| 组合动作 Alpha | 对固定 Alpha 执行 `easeOutQuad(alpha)`，例如 0.3 被改成 0.51 | 这不是按时间缓动，而是直接放大混合权重。应保留资源 Alpha，时间过渡交给轨道混合 |
| 动作速度 | 原始 Speed 再乘自设 `EmotionalWeights` | 与原版 `baseAnimTimeScale` 和强度速度策略不一致；应区分组内速度、基础速度与强度倍率，按资源所属范围应用，避免重复加强 |
| 动作互斥 | 每次播放新动作都会清空 2–10 轨道；没有统一的完成、优先级和占用调度 | 未完成动作及不冲突的部位动作也会中断。应按 `OccupancyLetters` 协调，明确触摸、语义动作和自动细节的优先级 |
| 固定语义映射 | `playful` 的坐姿首选双手比耶，`comfort` 首选双手伸向用户；总是选择首个兼容项 | 普通玩笑和安慰容易被放大成夸张手势。应结合意图、表情强度、姿态、资源权重选择；轻度安慰只需表情与轻倾身 |
| 表情切换 | 每种心情手写 1–3 组眼眉；讲话每 1.5–3.1 秒强制选择不同变体；统一 0.16 秒混合 | 即使情绪没有变化也换脸。应使用原始完整表情组合与情绪混合时间，在一句或一个连续情绪段中保持 |
| TTS 分句重启 | 每段应用一次表情，开始说话再应用，结束说话又应用；随后固定延迟回 neutral | 眨眼与表情节奏不断重置。连续回复应共享 talk 状态，音频句间只关闭嘴，不重复初始化整张脸 |

主要代码入口：

- `lib/src/chat_segments.dart`：`performanceSegmentsForAssistantResponse`、`performanceCueForAssistantResponse`。
- `lib/src/chat_screen.dart`：`_applyPerformanceFromResponse`、`_performSemanticAction`、`_playMotionGroup`、`_resetMotionOverlays`、`_applySpeakingHeadMotion`、`_scheduleMicroMotion`、`_applyExpression`、`_startSpeakingAnimation`、`_stopSpeakingAnimation`。
- `lib/src/character_appearance.dart`：`loadCharacterMotionGroups`、`selectCharacterAmbientMotionGroup`。
- `lib/src/character_speech_driver.dart`：`CharacterPerformanceProfile.parse`、`CharacterPerformanceDirector.sample`。
- `lib/src/character_expression.dart`、`lib/src/character_performance.dart`：当前手写映射。

`enhanced_animation_system.dart` 中部分 helper 和 procedural timer 类没有被实例化，不能把文件里所有定时器都视为正在运行。上述额外正弦运动实际位于 `chat_screen.dart`。

## 原版已经提供、值得复用的数据

原始坐姿文件：
`../assets/flutter_assets/assets/spine/crf_chr_002/crf_skn_002_0001_01/crf_skn_002_0001_01_gesture.json`。

站姿使用同目录下 `crf_skn_002_0001_99` 的配置；换装时必须读取当前服装自己的映射，不能一律套用坐姿表。

| 原始配置 | 可复用的职责 | 当前缺口 |
| --- | --- | --- |
| `EmotionProfilesV4` | 9 种情绪及 weak/normal/strong 三档配置 | 当前主要读取 normal 的手臂权重，视觉强度未完整接入 |
| `expressionSets` | 成套选择 eyeOpen、eyeClosed、eyebrow、mouth | 当前眼眉和嘴分别由手写小表驱动，失去原配组合关系 |
| `mixDurationEye` / `mixDurationEyebrow` | 情绪各自的面部过渡速度 | 当前统一为 0.16 秒 |
| `basePoses` | 按情绪、姿态类型、坐姿兼容性和权重选择基础姿态 | 当前闲置从 appearance 的动作列表随机挑选 |
| `armGroupWeights` / `armGroupWeightsByPoseType` | 情绪与姿态限定下的手臂候选权重 | 随机探索可能绕开权重为零的限制；姿态键需要完整解析 |
| `fixedGestureBindingsByAttitude` | agree/deny/question 对应的动作、眼神与权重 | 当前赞同/否定/提问大多用固定 one-shot，不按情绪选择 |
| `DriverDefs[].Spec` | 头身眼目标角度、过渡、保持、跟随关系 | 当前只选 `_n_` 驱动，并用通用插值与自定义骨骼幅度近似 |
| `MotionGroups` | 组内动画、Alpha、Speed、BlendTime、轨道占用和兼容姿势 | 动画已接入，但 Alpha/Speed 被二次改写；同组 ID 的变体需要保留 |
| `projectConfig` | 手臂出入、基础姿态锁定、视线和口型等配置 | 应按功能单独核对，不能仅复制字段就宣称复刻完成 |

坐姿 normal 档中已确认的表情组合数：neutral 60、happy 36、sad 24、angry 16、shy 63、tease 315。这些是组件组合数量，不等于同样数量的独立情绪，也不应快速轮播所有组合。

具体例子：

- 原版 sad 的眼眉混合约 0.58 秒，happy 约 0.24 秒；悲伤的变化本来更缓慢。
- 原版 sad 的否定动作中 D007 权重为 1，D003 权重为 0，并配合 `lookAway`；当前 `disagree` 通常固定走 D003。按“情绪 × 态度”选择比统一摇头更有区分度。
- 原版 `neutral_n_1` 先用 1–1.6 秒过渡到目标，再保持约 0.5–1.2 秒，并让身体延迟跟随。复用这种“动作—停留”节奏，比持续正弦摇摆更合适。
- 旧坐姿的 140 条 MotionGroups 实际包含 95 个 GroupId，其中有变体，不应把条目数理解成 140 种独立语义动作。
- `projectConfig.armInOutPartConfig` 提供手臂出入的中间姿势、0.4–1 秒路由时长和双臂起始错开等配置。这是改善手部突然切姿的依据，需要在播放端重建路由，单纯增加 MixDuration 不能替代。

### 外层新版资源还有另一套语义模式

`../firebase_distribution_test_2026-09-06/` 的新版 0002–0005 配置改用 `GesturePatternDefs` 和 `AttitudePatterns`，仍标记 `schemaVersion: 4`。抽查 0002/r3 文件有 21 条模式定义、57 条态度映射，没有 `DriverDefs`。

其中 `talk_low` 的一条记录表示普通看向前方：模式 D1、权重 0.4、中等停留、普通速度、重复 2–4 次。它提供了“语义状态—运动模式—大小—速度—停留—重复”的直接配置依据，比随机挑全身动作更适合后续细化控制。

新版 A1“思考/回想”模式为眼睛看上方或斜上方、头部弱跟随、身体不动；A3“思索/低落”是向下或斜下、头部强跟随，身体保持。`ambientGaze` 另有停留、速度和头身跟随延迟。这些配置说明“生动”可以由眼神先动、头部随后响应、身体有选择地参与实现，不需要所有部位始终一起摇动。

当前 Demo 实际打包的两个可动角色配置仍是旧格式，各有 98 条 `DriverDefs`；另外三套服装目前在 `character_appearance.dart` 标记为静态预览。因此新版格式不是当前常服多动的直接原因，但后续接入新版资源时必须按字段能力兼容两套格式，不能只判断 schemaVersion，也不能继续只读取 DriverDefs。

## 建议的控制协议和映射

保留现有 `[face:*]` / `[action:*]` 协议，兼容旧对话。若增加控制字段，推荐只增加可选的视觉强度与态度，例如 `[level:weak]`、`[attitude:deny]`。这是后续设计建议，当前解析器尚未实现，不能直接要求当前版本的 LLM 输出这些新标签。

视觉强度独立于 Fish 的感情程度和句内标签密度；不要把提高 TTS 情感直接解释为提高全身动作频率。

| 场景 | 高层选择 | 建议画面反应 |
| --- | --- | --- |
| 平常说明 | neutral / normal / explain 或 none | 保持基础姿态，主要由眼神与嘴型回应；需要指出重点时才轻手势 |
| 有些失落 | sad / weak / none | 原配悲伤脸、轻微低头、缓慢过渡并停留 |
| 安慰用户 | cuddle 或 sad / weak / comfort | 柔和目光和轻倾身；不默认伸双手拥抱 |
| 悲伤地拒绝 | sad / normal / deny | 优先原版 sad 的态度绑定，避开强烈反驳动作 |
| 严肃反驳 | angry / normal / deny | 收紧眉眼，必要时一次明确的否定动作，然后稳定保持 |
| 害羞或被夸 | shy / weak / none | 原版害羞表情与短暂移开视线，不重复摸脸、摆手 |
| 开心发现 | happy / normal / acknowledge | 一次轻点头或原配小手势，之后继续说话 |
| 明确庆祝 | happy/laughing / strong / excited | 允许一次较大动作，结束后回到相容的基础姿态 |

这些是应用层语义映射建议；资源本身并未提供相同名称的完整 LLM 协议。

## 推荐实施顺序

1. 修复 `none` 及流式事件重复消费；TTS 和文字路径共用按台词产生的一次性动作事件。
2. 合并 idle/talk/触摸状态的调度，连续回复内保持 face 和姿态。大动作以完成事件和占用情况衔接，不靠多个独立定时器抢轨。
3. 去除重复正弦层、讲话期间的随机大动作探索和静态 Alpha 放大，保留当前姿态兼容检查及防骨骼偏移累积的保护。
4. 加载原始 expressionSets、视觉强度、态度绑定、姿势权重和混合参数；先覆盖坐姿、站姿，再逐套服装验证。
5. 音频能量主要用于口型，最多影响轻量节奏。Android 当前使用 MP3，`tryParseWav` 无法得到包络，通常会走固定节奏降级；需要另行获得解码后的 PCM/包络，不能把现有播放进度称作真实声音分析，也不应贸然取消 MP3 的设备兼容处理。
6. 记录“哪条台词、为何选此动作、被谁抑制、何时开始/结束”的演出事件，方便对比；不要靠肉眼猜测随机动作来源。

## 验证与限制

- 已运行 `test/character_speech_driver_test.dart`：4 项通过。
- 已运行现有表情、动作、资源池和轨道映射相关测试：11 项通过。
- 这些检查覆盖解析、资源引用、插值不累积等行为，不代表自然度验收通过；当前测试也没有覆盖 `none` 引发的流式旧动作重播。
- 未运行原版和 Demo 的同台词视觉对照；没有完整原版 Dart 控制器，因此不能承诺逐帧一致。
- 未修改应用行为、未构建 APK、未发布素材。本报告只记录实现方式、字段名和少量映射示例。
