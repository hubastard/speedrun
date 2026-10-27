// What shows over any screen: the toast, and the popups an app shows "sometimes" — the
// notification prompt after sign in (then the system's own alert), a rating prompt and a
// badge after the first order (native modals), a survey sheet after the second.
import LottieView from 'lottie-react-native';
import * as Notifications from 'expo-notifications';
import React, { useState } from 'react';
import { Modal, Text, View } from 'react-native';
import Animated, { FadeInUp, FadeOutUp } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { closePopup, useStore } from './store';
import { Body, Button, Chip, s, Sheet, Title, useColors } from './ui';

export function ToastHost() {
  const c = useColors();
  const insets = useSafeAreaInsets();
  const t = useStore((st) => st.toast);
  if (!t) return null;
  return (
    <Animated.View
      key={t.id}
      entering={FadeInUp}
      exiting={FadeOutUp}
      pointerEvents="none"
      style={{ position: 'absolute', top: insets.top + 8, left: 24, right: 24, backgroundColor: c.text, borderRadius: 12, padding: 14 }}
    >
      <Text testID="toast" style={{ color: c.bg, fontWeight: '700', textAlign: 'center' }}>{t.text}</Text>
    </Animated.View>
  );
}

export function PopupHost() {
  const popup = useStore((st) => st.popups[0]);
  return (
    <>
      <NotifyPrompt visible={popup === 'notify'} />
      <RateModal visible={popup === 'rate'} />
      <BadgeModal visible={popup === 'badge'} />
      <Survey visible={popup === 'survey'} />
    </>
  );
}

function Card({ children }: { children: React.ReactNode }) {
  const c = useColors();
  return (
    <View style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.45)', justifyContent: 'center', padding: 28 }}>
      <View style={[s.card, { backgroundColor: c.bg, padding: 20 }]}>{children}</View>
    </View>
  );
}

function NotifyPrompt({ visible }: { visible: boolean }) {
  if (!visible) return null;
  return (
    <View style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0 }}>
      <Card>
        <Title testID="notify-title">Turn on notifications</Title>
        <Body muted>Get updates about your orders and messages.</Body>
        <Button
          testID="notify-on"
          title="Turn on"
          onPress={async () => {
            closePopup('notify');
            try {
              await Notifications.requestPermissionsAsync();
            } catch {}
          }}
        />
        <Button testID="notify-later" kind="secondary" title="Not now" onPress={() => closePopup('notify')} />
      </Card>
    </View>
  );
}

function RateModal({ visible }: { visible: boolean }) {
  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={() => closePopup('rate')}>
      <Card>
        <Title testID="rate-title">Enjoying Speedrun Bench</Title>
        <Body muted>Tell others what you think with a rating.</Body>
        <Button testID="rate-yes" title="Rate us" onPress={() => closePopup('rate')} />
        <Button testID="rate-later" kind="secondary" title="Not now" onPress={() => closePopup('rate')} />
      </Card>
    </Modal>
  );
}

function BadgeModal({ visible }: { visible: boolean }) {
  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={() => closePopup('badge')}>
      <Card>
        <LottieView source={require('../assets/spinner.json')} autoPlay loop style={{ width: 100, height: 100, alignSelf: 'center' }} />
        <Title testID="badge-title">Badge unlocked</Title>
        <Body muted>First order: you earned the Starter badge.</Body>
        <Button testID="badge-close" title="Nice" onPress={() => closePopup('badge')} />
      </Card>
    </Modal>
  );
}

function Survey({ visible }: { visible: boolean }) {
  const c = useColors();
  const [score, setScore] = useState<number | null>(null);
  return (
    <Sheet visible={visible} onClose={() => closePopup('survey')} testID="survey">
      <Title testID="survey-title">How likely are you to recommend us</Title>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', marginVertical: 8 }}>
        {Array.from({ length: 11 }, (_, i) => <Chip key={i} testID={`nps-${i}`} label={String(i)} selected={score === i} onPress={() => setScore(i)} />)}
      </View>
      <Text style={{ color: c.muted, marginBottom: 8 }}>{score === null ? 'Pick a score' : `Your score: ${score}`}</Text>
      <Button testID="nps-submit" title="Submit" disabled={score === null} onPress={() => closePopup('survey')} />
      <Button testID="nps-close" kind="secondary" title="Close" onPress={() => closePopup('survey')} />
    </Sheet>
  );
}
