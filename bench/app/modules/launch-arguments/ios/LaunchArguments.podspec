Pod::Spec.new do |s|
  s.name           = 'LaunchArguments'
  s.version        = '1.0.0'
  s.summary        = 'The launch arguments of the benchmark app'
  s.description    = 'The launch arguments of the benchmark app'
  s.author         = ''
  s.homepage       = 'https://github.com/hubastard/speedrun'
  s.platforms      = { :ios => '15.1' }
  s.source         = { git: '' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.source_files = "**/*.swift"
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
