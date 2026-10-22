Pod::Spec.new do |s|
  s.name             = 'live2d_flutter'
  s.version          = '1.0.3'
  s.summary          = 'Flutter plugin for Live2D Cubism SDK.'
  s.description      = 'Renders Live2D Cubism models in a macOS platform view.'
  s.homepage         = 'https://github.com/hunmer/flutter_live2d'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'linh18nd' => 'linh18nd@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'live2d_flutter/Sources/live2d_flutter/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.frameworks = ['Network', 'WebKit']
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
