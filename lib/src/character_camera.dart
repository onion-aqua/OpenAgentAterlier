import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

const characterCameraGestureKey = ValueKey('character-stage-gesture');
const characterCameraTransformKey = ValueKey('character-camera-transform');
const characterCameraOffsetKey = ValueKey('character-camera-offset');

/// A single pointer sample in the character's unscaled scene coordinates.
@immutable
class CharacterTouchSample {
  const CharacterTouchSample({
    required this.position,
    required this.timeStamp,
    required this.velocity,
  });

  /// The same coordinate system used by [CharacterCamera.onTap].
  final Offset position;

  /// Pointer event time, independent of wall-clock changes and render timing.
  final Duration timeStamp;

  /// Scene widths/heights per second, with camera and scene fitting removed.
  /// A value of (1, 0) moves one whole scene width per second to the right.
  final Offset velocity;
}

class CharacterCamera extends StatefulWidget {
  const CharacterCamera({
    super.key,
    required this.child,
    required this.onTap,
    this.onGazeChanged,
    this.onGazeEnd,
    this.onCharacterDragStart,
    this.onCharacterDragUpdate,
    this.onCharacterDragEnd,
    this.onCharacterTouchStart,
    this.onCharacterTouchMove,
    this.onCharacterTouchEnd,
    this.minScale = 0.8,
    this.maxScale = 2.2,
    this.initialScale = 1.25,
    this.initialVerticalOffsetFraction = 0.2,
    this.keepSceneProportions = false,
    this.semanticLabel = '角色，点击触发互动',
  });

  final Widget child;
  final ValueChanged<Offset> onTap;
  final ValueChanged<Offset>? onGazeChanged;
  final VoidCallback? onGazeEnd;

  /// Called after the pointer crosses the drag slop. Return true only when the
  /// original press hit a draggable character region. All positions use the
  /// same scene coordinates as [onTap].
  final bool Function(Offset)? onCharacterDragStart;
  final ValueChanged<Offset>? onCharacterDragUpdate;
  final VoidCallback? onCharacterDragEnd;

  /// Independent single-pointer input for physics, including sub-slop motion
  /// and motion captured by [onCharacterDragStart]. Both start and move must
  /// be supplied to enable sampling. These callbacks do not consume gestures.
  final ValueChanged<CharacterTouchSample>? onCharacterTouchStart;
  final ValueChanged<CharacterTouchSample>? onCharacterTouchMove;
  final VoidCallback? onCharacterTouchEnd;
  final double minScale;
  final double maxScale;
  final double initialScale;
  final double initialVerticalOffsetFraction;
  final bool keepSceneProportions;
  final String semanticLabel;

  @override
  State<CharacterCamera> createState() => _CharacterCameraState();
}

class _CharacterCameraState extends State<CharacterCamera>
    with WidgetsBindingObserver {
  late double _scale;
  double _scaleAtGestureStart = 1;
  double? _verticalOffset;
  Size? _referenceSceneSize;
  bool _pinchDetected = false;
  bool _suppressTap = false;
  Timer? _tapSuppressionTimer;
  final Set<int> _pointers = {};
  int? _characterDragPointer;
  Offset? _characterDragOrigin;
  bool _characterDragging = false;
  bool _characterDragRejected = false;
  bool _characterDragSuppressTap = false;
  VoidCallback? _activeCharacterDragEnd;
  int? _characterTouchPointer;
  Offset? _previousTouchPosition;
  Duration? _previousTouchTime;
  VoidCallback? _activeCharacterTouchEnd;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scale = widget.initialScale.clamp(widget.minScale, widget.maxScale);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSuppressionTimer?.cancel();
    _endCharacterDrag();
    _endCharacterTouch();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CharacterCamera oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onCharacterDragStart == null ||
        widget.onCharacterDragUpdate == null) {
      _endCharacterDrag();
    }
    if (widget.onCharacterTouchStart == null ||
        widget.onCharacterTouchMove == null) {
      _endCharacterTouch();
    }
  }

  void _endCharacterTouch() {
    final end = _characterTouchPointer != null
        ? _activeCharacterTouchEnd
        : null;
    _characterTouchPointer = null;
    _previousTouchPosition = null;
    _previousTouchTime = null;
    _activeCharacterTouchEnd = null;
    end?.call();
  }

  CharacterTouchSample _touchSample(
    PointerEvent event,
    Size stageSize,
    double verticalOffset,
  ) {
    final position = _unscalePosition(
      event.localPosition,
      stageSize,
      verticalOffset,
    );
    final previousPosition = _previousTouchPosition;
    final previousTime = _previousTouchTime;
    final elapsed = previousTime == null
        ? 0
        : (event.timeStamp - previousTime).inMicroseconds;
    final sceneSize = widget.keepSceneProportions
        ? (_referenceSceneSize ?? stageSize)
        : stageSize;
    var velocity = Offset.zero;
    // A long press or an interrupted event stream establishes a fresh speed
    // baseline instead of treating accumulated movement as a sudden flick.
    if (previousPosition != null &&
        elapsed > 0 &&
        elapsed <= 100000 &&
        sceneSize.width > 0 &&
        sceneSize.height > 0) {
      final delta = position - previousPosition;
      final seconds = elapsed / Duration.microsecondsPerSecond;
      velocity = Offset(
        delta.dx / sceneSize.width / seconds,
        delta.dy / sceneSize.height / seconds,
      );
    }
    _previousTouchPosition = position;
    _previousTouchTime = event.timeStamp;
    return CharacterTouchSample(
      position: position,
      timeStamp: event.timeStamp,
      velocity: velocity,
    );
  }

  void _endCharacterDrag() {
    final end = _characterDragging ? _activeCharacterDragEnd : null;
    _characterDragging = false;
    _activeCharacterDragEnd = null;
    _characterDragPointer = null;
    _characterDragOrigin = null;
    _characterDragRejected = false;
    end?.call();
  }

  void _resetPointers() {
    final suppressTap = _pinchDetected || _pointers.length > 1 || _suppressTap;
    _endCharacterDrag();
    _endCharacterTouch();
    _pointers.clear();
    _pinchDetected = false;
    // ScaleEnd may arrive after focus/lifecycle reset and no longer carry the
    // pinch flag. Own the short suppression window here so it cannot stick.
    if (suppressTap) _suppressTapsBriefly();
    widget.onGazeEnd?.call();
  }

  void _suppressTapsBriefly() {
    _suppressTap = true;
    _tapSuppressionTimer?.cancel();
    _tapSuppressionTimer = Timer(
      const Duration(milliseconds: 280),
      () => _suppressTap = false,
    );
  }

  void _removePointer(int pointer) {
    if (pointer == _characterDragPointer) _endCharacterDrag();
    if (pointer == _characterTouchPointer) _endCharacterTouch();
    _pointers.remove(pointer);
    if (_pointers.isEmpty && _pinchDetected) {
      // A two-finger tap need not win the scale gesture arena, so there may be
      // no ScaleEnd callback to clear its flag or suppress the trailing tap.
      _pinchDetected = false;
      _suppressTapsBriefly();
    }
    widget.onGazeEnd?.call();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused &&
        event.viewId == View.of(context).viewId) {
      _resetPointers();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _resetPointers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 0 && constraints.maxHeight > 0) {
          _referenceSceneSize ??= constraints.biggest;
        }
        final referenceSize = _referenceSceneSize ?? constraints.biggest;
        final verticalOffset =
            _verticalOffset ??
            constraints.maxHeight * widget.initialVerticalOffsetFraction;
        return Semantics(
          button: true,
          label: widget.semanticLabel,
          child: Listener(
            onPointerDown: (event) {
              _pointers.add(event.pointer);
              if (_pointers.length == 1) {
                _pinchDetected = false;
                _characterDragSuppressTap = false;
                if ((event.kind == PointerDeviceKind.touch ||
                        event.kind == PointerDeviceKind.mouse) &&
                    event.buttons == kPrimaryButton &&
                    widget.onCharacterTouchStart != null &&
                    widget.onCharacterTouchMove != null) {
                  _characterTouchPointer = event.pointer;
                  _activeCharacterTouchEnd = widget.onCharacterTouchEnd;
                  widget.onCharacterTouchStart!.call(
                    _touchSample(event, constraints.biggest, verticalOffset),
                  );
                }
                if ((event.kind == PointerDeviceKind.touch ||
                        event.kind == PointerDeviceKind.mouse) &&
                    event.buttons == kPrimaryButton &&
                    widget.onCharacterDragStart != null &&
                    widget.onCharacterDragUpdate != null &&
                    !_suppressTap) {
                  _characterDragPointer = event.pointer;
                  _characterDragOrigin = event.localPosition;
                }
                widget.onGazeChanged?.call(
                  _unscalePosition(
                    event.localPosition,
                    constraints.biggest,
                    verticalOffset,
                  ),
                );
              } else {
                _endCharacterDrag();
                _endCharacterTouch();
                _pinchDetected = true;
                widget.onGazeEnd?.call();
              }
            },
            onPointerMove: (event) {
              if (event.pointer == _characterTouchPointer) {
                if (event.buttons != kPrimaryButton) {
                  _endCharacterTouch();
                } else if (_pointers.length == 1 && !_pinchDetected) {
                  widget.onCharacterTouchMove?.call(
                    _touchSample(event, constraints.biggest, verticalOffset),
                  );
                }
              }
              if (event.pointer == _characterDragPointer) {
                if (event.buttons != kPrimaryButton) {
                  _endCharacterDrag();
                } else if (_pointers.length == 1 && !_pinchDetected) {
                  final origin = _characterDragOrigin;
                  if (!_characterDragging &&
                      !_characterDragRejected &&
                      origin != null &&
                      (event.localPosition - origin).distance >
                          computeHitSlop(
                            event.kind,
                            MediaQuery.maybeGestureSettingsOf(context),
                          )) {
                    _characterDragging =
                        widget.onCharacterDragStart?.call(
                          _unscalePosition(
                            origin,
                            constraints.biggest,
                            verticalOffset,
                          ),
                        ) ??
                        false;
                    _characterDragRejected = !_characterDragging;
                    if (_characterDragging) {
                      _activeCharacterDragEnd = widget.onCharacterDragEnd;
                      _characterDragSuppressTap = true;
                      widget.onGazeEnd?.call();
                    }
                  }
                  if (_characterDragging) {
                    widget.onCharacterDragUpdate?.call(
                      _unscalePosition(
                        event.localPosition,
                        constraints.biggest,
                        verticalOffset,
                      ),
                    );
                    return;
                  }
                }
              }
              if (_pointers.length == 1 && !_pinchDetected && !_suppressTap) {
                widget.onGazeChanged?.call(
                  _unscalePosition(
                    event.localPosition,
                    constraints.biggest,
                    verticalOffset,
                  ),
                );
              }
            },
            onPointerUp: (event) {
              _removePointer(event.pointer);
            },
            onPointerCancel: (event) {
              _removePointer(event.pointer);
            },
            child: GestureDetector(
              key: characterCameraGestureKey,
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                if (_pinchDetected ||
                    _suppressTap ||
                    _characterDragSuppressTap) {
                  return;
                }
                widget.onTap(
                  _unscalePosition(
                    details.localPosition,
                    constraints.biggest,
                    verticalOffset,
                  ),
                );
              },
              onScaleStart: (details) {
                _scaleAtGestureStart = _scale;
                _verticalOffset ??= verticalOffset;
                _pinchDetected = details.pointerCount > 1;
              },
              onScaleUpdate: (details) {
                if (details.pointerCount == 1) {
                  return;
                }
                if (details.pointerCount < 2) return;
                _pinchDetected = true;
                _suppressTap = true;
                final nextScale = (_scaleAtGestureStart * details.scale).clamp(
                  widget.minScale,
                  widget.maxScale,
                );
                final maxDown = constraints.maxHeight * 0.55;
                final maxUp = constraints.maxHeight * 0.35;
                final currentOffset = _verticalOffset ?? verticalOffset;
                final nextOffset = (currentOffset + details.focalPointDelta.dy)
                    .clamp(-maxUp, maxDown);
                if ((nextScale - _scale).abs() < 0.001 &&
                    (nextOffset - currentOffset).abs() < 0.1) {
                  return;
                }
                setState(() {
                  _scale = nextScale;
                  _verticalOffset = nextOffset;
                });
              },
              onScaleEnd: (_) {
                if (_pinchDetected) _suppressTapsBriefly();
                _pinchDetected = false;
              },
              child: Transform.translate(
                key: characterCameraOffsetKey,
                offset: Offset(0, verticalOffset),
                child: Transform.scale(
                  key: characterCameraTransformKey,
                  scale: _scale,
                  alignment: Alignment.bottomCenter,
                  child: widget.keepSceneProportions
                      ? SizedBox.expand(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomCenter,
                            child: SizedBox.fromSize(
                              size: referenceSize,
                              child: widget.child,
                            ),
                          ),
                        )
                      : widget.child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Offset _unscalePosition(
    Offset position,
    Size stageSize,
    double verticalOffset,
  ) {
    final translated = position - Offset(0, verticalOffset);
    final origin = Offset(stageSize.width / 2, stageSize.height);
    final cameraPosition = origin + (translated - origin) / _scale;
    final reference = _referenceSceneSize;
    if (!widget.keepSceneProportions || reference == null) {
      return cameraPosition;
    }
    final fitScale = math.min(
      stageSize.width / reference.width,
      stageSize.height / reference.height,
    );
    if (fitScale <= 0) return cameraPosition;
    final sceneOrigin = Offset(
      (stageSize.width - reference.width * fitScale) / 2,
      stageSize.height - reference.height * fitScale,
    );
    return (cameraPosition - sceneOrigin) / fitScale;
  }
}
