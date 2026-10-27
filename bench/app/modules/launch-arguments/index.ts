import { requireNativeModule } from 'expo';

// The arguments launchApp passed: `-key value` launch arguments on iOS, intent extras on Android.
const native = requireNativeModule<{ get(): Record<string, string> }>('LaunchArguments');

export function launchArguments(): Record<string, string> {
  return native.get();
}
