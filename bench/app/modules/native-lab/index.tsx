import { requireNativeView } from 'expo';
import React from 'react';
import type { ViewProps } from 'react-native';

// A screen of the platform's own UI toolkit: Jetpack Compose on Android, SwiftUI on iOS, with
// the same texts and identifiers. See NativeLabModule.kt and NativeLabModule.swift.
let Native: React.ComponentType<ViewProps> | null = null;

export function NativeLabView(props: ViewProps) {
  const View = (Native ??= requireNativeView<ViewProps>('NativeLab'));
  return <View {...props} />;
}
