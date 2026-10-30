import { requireNativeView } from 'expo';
import React from 'react';
import type { ViewProps } from 'react-native';

// A Jetpack Compose screen (Android only: the module has no iOS side). See ComposeLabModule.kt.
let Native: React.ComponentType<ViewProps> | null = null;

export function ComposeLabView(props: ViewProps) {
  const View = (Native ??= requireNativeView<ViewProps>('ComposeLab'));
  return <View {...props} />;
}
