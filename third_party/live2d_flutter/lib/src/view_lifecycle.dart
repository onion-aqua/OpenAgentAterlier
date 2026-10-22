abstract interface class Live2DViewLifecycle {
  Future<void> initializeView({required int viewId});

  Future<void> disposeView({required int viewId});
}
