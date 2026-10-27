// Shared building blocks. Every control a flow drives has a testID (iOS: identifier, Android:
// resource id) or a single text, so the same selector works on both platforms.
import { useNavigation } from '@react-navigation/native';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, TextInputProps,
  useColorScheme, View, ViewStyle,
} from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  Easing, runOnJS, useAnimatedStyle, useSharedValue, withRepeat, withSequence, withSpring,
  withTiming,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

// ---- colors ----

const LIGHT = {
  bg: '#ffffff', card: '#f3f4f6', text: '#111827', muted: '#6b7280', border: '#e5e7eb',
  accent: '#4f46e5', accentText: '#ffffff', danger: '#dc2626', ok: '#059669', shimmer: '#e5e7eb',
};
const DARK: typeof LIGHT = {
  bg: '#0b0f19', card: '#161b26', text: '#f9fafb', muted: '#9ca3af', border: '#1f2937',
  accent: '#818cf8', accentText: '#0b0f19', danger: '#f87171', ok: '#34d399', shimmer: '#1f2937',
};
export type Colors = typeof LIGHT;

export function useColors(): Colors {
  return useColorScheme() === 'dark' ? DARK : LIGHT;
}

// ---- layout ----

export function Header({ title, back = true, right }: { title: string; back?: boolean; right?: React.ReactNode }) {
  const c = useColors();
  const nav = useNavigation<any>();
  return (
    <View style={[s.header, { borderColor: c.border }]}>
      <View style={s.headerSide}>
        {back && nav.canGoBack() ? (
          <Pressable testID="header-back" accessibilityRole="button" accessibilityLabel="Back" hitSlop={12} onPress={() => nav.goBack()}>
            <Text style={[s.headerBack, { color: c.accent }]}>‹ Back</Text>
          </Pressable>
        ) : null}
      </View>
      <Text accessibilityRole="header" style={[s.headerTitle, { color: c.text }]} numberOfLines={1}>{title}</Text>
      <View style={[s.headerSide, { alignItems: 'flex-end' }]}>{right}</View>
    </View>
  );
}

// overlay: drawn over the body, below the header (as a native navigation bar stays above a
// screen's own views), from above the body's top edge (the body sits below a padding).
export function Screen({
  title, back, right, children, scroll = true, footer, testID, overlay,
}: {
  title: string; back?: boolean; right?: React.ReactNode; children: React.ReactNode; scroll?: boolean;
  footer?: React.ReactNode; testID?: string; overlay?: React.ReactNode;
}) {
  const c = useColors();
  const insets = useSafeAreaInsets();
  const body = scroll ? (
    <ScrollView keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag" contentContainerStyle={{ padding: 16, paddingBottom: footer ? 120 : 40 }}>
      {children}
    </ScrollView>
  ) : (
    <View style={{ flex: 1 }}>{children}</View>
  );
  return (
    <View testID={testID} style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title={title} back={back} right={right} />
      {overlay ? (
        <View style={{ flex: 1, paddingTop: 8 }}>
          {body}
          {overlay}
        </View>
      ) : (
        body
      )}
      {footer ? (
        <View style={[s.footer, { backgroundColor: c.bg, borderColor: c.border, paddingBottom: 12 + insets.bottom }]}>{footer}</View>
      ) : null}
    </View>
  );
}

// A loading overlay over a screen's body (Screen's overlay): fades in with a spinner while
// `loading`, out after. Always mounted, transparent when idle; see-through while loading, the
// controls behind it showing, but taking the touches. The spinner fills it (flex: 1).
export function Fade({ loading }: { loading: boolean }) {
  const c = useColors();
  const opacity = useSharedValue(0);
  useEffect(() => {
    opacity.value = withTiming(loading ? 1 : 0, { duration: 250 });
  }, [loading, opacity]);
  const shown = useAnimatedStyle(() => ({ opacity: opacity.value }));
  return (
    <Animated.View
      pointerEvents={loading ? 'auto' : 'none'}
      style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0, 0, 0, 0.25)', justifyContent: 'center', alignItems: 'center' }, shown]}
    >
      <ActivityIndicator size="large" color={c.accent} style={{ flex: 1, alignSelf: 'stretch' }} />
    </Animated.View>
  );
}

export function Title({ children, testID }: { children: React.ReactNode; testID?: string }) {
  const c = useColors();
  return <Text testID={testID} accessibilityRole="header" style={[s.title, { color: c.text }]}>{children}</Text>;
}

export function Body({ children, testID, muted, style }: { children: React.ReactNode; testID?: string; muted?: boolean; style?: any }) {
  const c = useColors();
  return <Text testID={testID} style={[s.body, { color: muted ? c.muted : c.text }, style]}>{children}</Text>;
}

export function Gap({ h = 12 }: { h?: number }) {
  return <View style={{ height: h }} />;
}

// ---- controls ----

export function Button({
  title, onPress, disabled, testID, kind = 'primary', style,
}: {
  title: string; onPress?: () => void; disabled?: boolean; testID?: string; kind?: 'primary' | 'secondary' | 'danger'; style?: ViewStyle;
}) {
  const c = useColors();
  const bg = kind === 'primary' ? c.accent : kind === 'danger' ? c.danger : c.card;
  const fg = kind === 'secondary' ? c.text : c.accentText;
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityState={{ disabled: !!disabled }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [s.button, { backgroundColor: bg, opacity: disabled ? 0.4 : pressed ? 0.7 : 1 }, style]}
    >
      <Text style={[s.buttonText, { color: fg }]}>{title}</Text>
    </Pressable>
  );
}

export function Row({ title, detail, onPress, testID }: { title: string; detail?: string; onPress?: () => void; testID?: string }) {
  const c = useColors();
  return (
    <Pressable testID={testID} accessibilityRole="button" onPress={onPress} style={[s.row, { borderColor: c.border }]}>
      <Text style={[s.body, { color: c.text, flex: 1 }]}>{title}</Text>
      {detail ? <Text style={[s.body, { color: c.muted }]}>{detail}</Text> : null}
      <Text style={[s.body, { color: c.muted, marginLeft: 8 }]}>›</Text>
    </Pressable>
  );
}

export function Checkbox({ label, checked, onChange, testID }: { label: string; checked: boolean; onChange: (v: boolean) => void; testID?: string }) {
  const c = useColors();
  return (
    <Pressable testID={testID} accessibilityRole="checkbox" accessibilityLabel={label} accessibilityState={{ checked }} onPress={() => onChange(!checked)} style={s.check}>
      <View style={[s.box, { borderColor: c.accent, backgroundColor: checked ? c.accent : 'transparent' }]}>
        {checked ? <Text style={{ color: c.accentText, fontWeight: '700' }}>✓</Text> : null}
      </View>
      <Text style={[s.body, { color: c.text }]}>{label}</Text>
    </Pressable>
  );
}

export function Radio({ label, selected, onPress, testID }: { label: string; selected: boolean; onPress: () => void; testID?: string }) {
  const c = useColors();
  return (
    <Pressable testID={testID} accessibilityRole="radio" accessibilityLabel={label} accessibilityState={{ checked: selected }} onPress={onPress} style={s.check}>
      <View style={[s.box, { borderRadius: 12, borderColor: c.accent }]}>
        {selected ? <View style={{ width: 12, height: 12, borderRadius: 6, backgroundColor: c.accent }} /> : null}
      </View>
      <Text style={[s.body, { color: c.text }]}>{label}</Text>
    </Pressable>
  );
}

export function Chip({ label, selected, onPress, testID }: { label: string; selected: boolean; onPress: () => void; testID?: string }) {
  const c = useColors();
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={onPress}
      style={[s.chip, { backgroundColor: selected ? c.accent : c.card }]}
    >
      <Text style={{ color: selected ? c.accentText : c.text, fontWeight: '600' }}>{label}</Text>
    </Pressable>
  );
}

export const Field = React.forwardRef<TextInput, TextInputProps & { label?: string; error?: string | null }>(
  function Field({ label, error, style, ...props }, ref) {
    const c = useColors();
    return (
      <View style={{ marginBottom: 12 }}>
        {label ? <Text style={[s.label, { color: c.muted }]}>{label}</Text> : null}
        <TextInput
          ref={ref}
          placeholderTextColor={c.muted}
          style={[s.field, { color: c.text, borderColor: error ? c.danger : c.border, backgroundColor: c.card }, style]}
          {...props}
        />
        {error ? <Text testID={props.testID ? `${props.testID}-error` : undefined} style={{ color: c.danger, marginTop: 4 }}>{error}</Text> : null}
      </View>
    );
  },
);

export function Spinner({ label = 'Loading' }: { label?: string }) {
  const c = useColors();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, padding: 8 }}>
      <ActivityIndicator color={c.accent} />
      <Text style={{ color: c.muted }}>{label}</Text>
    </View>
  );
}

// ---- animations ----

// A skeleton block with a highlight sweeping across it forever.
export function Shimmer({ height = 16, width = '100%' as any, style }: { height?: number; width?: any; style?: ViewStyle }) {
  const c = useColors();
  const x = useSharedValue(-1);
  useEffect(() => {
    x.value = withRepeat(withTiming(1, { duration: 1100, easing: Easing.linear }), -1);
  }, [x]);
  const sweep = useAnimatedStyle(() => ({ transform: [{ translateX: x.value * 300 }] }));
  return (
    <View style={[{ height, width, backgroundColor: c.shimmer, borderRadius: 8, overflow: 'hidden', marginBottom: 8 }, style]}>
      <Animated.View style={[{ width: 80, height: '100%', backgroundColor: 'rgba(255,255,255,0.45)' }, sweep]} />
    </View>
  );
}

// Text sliding right to left forever (a news ticker): it moves on every frame.
export function Marquee({ text, testID }: { text: string; testID?: string }) {
  const c = useColors();
  const x = useSharedValue(0);
  useEffect(() => {
    x.value = withRepeat(withTiming(-600, { duration: 8000, easing: Easing.linear }), -1);
  }, [x]);
  const move = useAnimatedStyle(() => ({ transform: [{ translateX: x.value }] }));
  return (
    <View style={{ overflow: 'hidden', backgroundColor: c.card, paddingVertical: 8 }}>
      <Animated.Text testID={testID} numberOfLines={1} style={[{ color: c.text, width: 1400, paddingLeft: 16 }, move]}>
        {text}
      </Animated.Text>
    </View>
  );
}

// Fades in and out forever (a "live" dot).
export function Pulse({ children, style }: { children: React.ReactNode; style?: ViewStyle }) {
  const o = useSharedValue(1);
  useEffect(() => {
    o.value = withRepeat(withSequence(withTiming(0.3, { duration: 600 }), withTiming(1, { duration: 600 })), -1);
  }, [o]);
  const fade = useAnimatedStyle(() => ({ opacity: o.value }));
  return <Animated.View style={[fade, style]}>{children}</Animated.View>;
}

// A number counting up to `to` on the JS thread, one text update per frame.
export function CountUp({ to, ms = 1200, prefix = '', testID, style }: { to: number; ms?: number; prefix?: string; testID?: string; style?: any }) {
  const c = useColors();
  const [v, setV] = useState(0);
  useEffect(() => {
    const start = Date.now();
    let frame = 0;
    const tick = () => {
      const t = Math.min(1, (Date.now() - start) / ms);
      setV(Math.round(to * t));
      if (t < 1) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [to, ms]);
  return <Text testID={testID} style={[{ color: c.text, fontSize: 28, fontWeight: '700' }, style]}>{prefix}{v}</Text>;
}

// Particles falling across the screen for ~2.5 s.
export function Confetti({ count = 40 }: { count?: number }) {
  return (
    <View pointerEvents="none" style={StyleSheet.absoluteFill}>
      {Array.from({ length: count }, (_, i) => <Particle key={i} i={i} />)}
    </View>
  );
}

const PALETTE = ['#f59e0b', '#ef4444', '#10b981', '#3b82f6', '#a855f7'];
function Particle({ i }: { i: number }) {
  const y = useSharedValue(-40);
  const r = useSharedValue(0);
  useEffect(() => {
    y.value = withTiming(900, { duration: 1800 + (i % 7) * 100, easing: Easing.in(Easing.quad) });
    r.value = withTiming(720, { duration: 2500 });
  }, [i, r, y]);
  const fall = useAnimatedStyle(() => ({ transform: [{ translateY: y.value }, { rotate: `${r.value}deg` }] }));
  return (
    <Animated.View
      style={[{ position: 'absolute', left: `${(i * 37) % 100}%`, width: 10, height: 14, borderRadius: 2, backgroundColor: PALETTE[i % PALETTE.length] }, fall]}
    />
  );
}

// A bottom sheet: springs up, closes on the backdrop or when dragged down.
export function Sheet({ visible, onClose, children, testID }: { visible: boolean; onClose: () => void; children: React.ReactNode; testID?: string }) {
  const c = useColors();
  const insets = useSafeAreaInsets();
  const y = useSharedValue(600);
  const [shown, setShown] = useState(visible);
  useEffect(() => {
    if (visible) {
      setShown(true);
      y.value = withSpring(0, { damping: 18, stiffness: 160 });
    } else {
      y.value = withTiming(600, { duration: 220 }, (done) => {
        if (done) runOnJS(setShown)(false);
      });
    }
  }, [visible, y]);
  const pan = Gesture.Pan()
    .onUpdate((e) => {
      y.value = Math.max(0, e.translationY);
    })
    .onEnd((e) => {
      if (e.translationY > 120 || e.velocityY > 800) runOnJS(onClose)();
      else y.value = withSpring(0);
    });
  const slide = useAnimatedStyle(() => ({ transform: [{ translateY: y.value }] }));
  if (!shown) return null;
  return (
    <View style={StyleSheet.absoluteFill}>
      <Pressable testID="sheet-backdrop" accessibilityLabel="Close sheet" style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.4)' }]} onPress={onClose} />
      <GestureDetector gesture={pan}>
        <Animated.View testID={testID} style={[s.sheet, { backgroundColor: c.bg, paddingBottom: 16 + insets.bottom }, slide]}>
          <View style={[s.grabber, { backgroundColor: c.border }]} />
          {children}
        </Animated.View>
      </GestureDetector>
    </View>
  );
}

export const s = StyleSheet.create({
  header: { height: 52, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  headerSide: { width: 90 },
  headerBack: { fontSize: 17 },
  headerTitle: { flex: 1, textAlign: 'center', fontSize: 17, fontWeight: '700' },
  footer: { position: 'absolute', left: 0, right: 0, bottom: 0, padding: 12, borderTopWidth: StyleSheet.hairlineWidth },
  title: { fontSize: 26, fontWeight: '800', marginBottom: 8 },
  body: { fontSize: 16 },
  label: { fontSize: 13, marginBottom: 4 },
  button: { paddingVertical: 14, paddingHorizontal: 18, borderRadius: 12, alignItems: 'center', marginVertical: 6 },
  buttonText: { fontSize: 16, fontWeight: '700' },
  row: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, borderBottomWidth: StyleSheet.hairlineWidth },
  check: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 8 },
  box: { width: 24, height: 24, borderRadius: 6, borderWidth: 2, alignItems: 'center', justifyContent: 'center' },
  chip: { paddingVertical: 8, paddingHorizontal: 14, borderRadius: 18, marginRight: 8, marginBottom: 8 },
  field: { borderWidth: 1, borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10, fontSize: 16 },
  sheet: { position: 'absolute', left: 0, right: 0, bottom: 0, borderTopLeftRadius: 20, borderTopRightRadius: 20, padding: 16 },
  grabber: { alignSelf: 'center', width: 40, height: 5, borderRadius: 3, marginBottom: 12 },
  card: { borderRadius: 14, padding: 14, marginBottom: 12 },
});
