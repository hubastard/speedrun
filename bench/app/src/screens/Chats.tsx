// Chats: a conversation list with unread badges, and a chat where the bot answers after
// "typing" (three dots bouncing forever while it types). A message opens a menu on long
// press (Copy, Delete) and takes a heart on double tap.
import { useNavigation, useRoute } from '@react-navigation/native';
import React, { useEffect, useRef, useState } from 'react';
import { FlatList, KeyboardAvoidingView, Platform, Pressable, ScrollView, Text, TextInput, View } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withDelay, withRepeat, withSequence, withTiming } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { CHATS } from '../data';
import { toast } from '../store';
import { Chip, Header, s, useColors } from '../ui';

export function Chats() {
  const c = useColors();
  const nav = useNavigation<any>();
  const insets = useSafeAreaInsets();
  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title="Chats" back={false} />
      <FlatList
        testID="chat-list"
        data={CHATS}
        keyExtractor={(ch) => ch.id}
        renderItem={({ item }) => (
          <Pressable testID={`chat-${item.id}`} accessibilityRole="button" onPress={() => nav.navigate('Chat', { id: item.id })} style={[s.row, { borderColor: c.border, paddingHorizontal: 16 }]}>
            <View style={{ flex: 1 }}>
              <Text style={{ color: c.text, fontWeight: '700' }}>{item.name}</Text>
              <Text style={{ color: c.muted }} numberOfLines={1}>{item.last}</Text>
            </View>
            {item.unread ? (
              <View style={{ backgroundColor: c.accent, borderRadius: 10, minWidth: 20, paddingHorizontal: 6, alignItems: 'center' }}>
                <Text style={{ color: c.accentText, fontWeight: '700' }}>{item.unread}</Text>
              </View>
            ) : null}
          </Pressable>
        )}
      />
    </View>
  );
}

type Message = { id: number; mine: boolean; text: string; heart: boolean };

const QUICK = ['Track my order', 'Return an item', 'Talk to a human'];

export function Chat() {
  const c = useColors();
  const route = useRoute<any>();
  const insets = useSafeAreaInsets();
  const chat = CHATS.find((ch) => ch.id === route.params?.id) ?? CHATS[0];
  const [messages, setMessages] = useState<Message[]>([{ id: 1, mine: false, text: chat.id === 'bot' ? 'Hi! Ask me anything.' : chat.last, heart: false }]);
  const [text, setText] = useState('');
  const [typing, setTyping] = useState(false);
  const [menu, setMenu] = useState<number | null>(null);
  const nextId = useRef(2);
  const lastTap = useRef<{ id: number; at: number }>({ id: 0, at: 0 });

  function send(body: string) {
    const t = body.trim();
    if (!t) return;
    setMessages((m) => [...m, { id: nextId.current++, mine: true, text: t, heart: false }]);
    setText('');
    setTimeout(() => setTyping(true), 400);
    setTimeout(() => {
      setTyping(false);
      setMessages((m) => [...m, { id: nextId.current++, mine: false, text: `You said: ${t}`, heart: false }]);
    }, 1900);
  }

  function tap(id: number) {
    const now = Date.now();
    if (lastTap.current.id === id && now - lastTap.current.at < 350) {
      setMessages((m) => m.map((x) => (x.id === id ? { ...x, heart: !x.heart } : x)));
      lastTap.current = { id: 0, at: 0 };
    } else lastTap.current = { id, at: now };
  }

  const shown = [...messages].reverse();
  return (
    <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : 'height'} style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title={chat.name} />
      <FlatList
        testID="messages"
        inverted
        keyboardShouldPersistTaps="handled"
        data={shown}
        keyExtractor={(m) => String(m.id)}
        contentContainerStyle={{ padding: 12 }}
        ListHeaderComponent={typing ? <Typing name={chat.name} /> : null}
        renderItem={({ item, index }) => (
          <Pressable
            testID={`message-${messages.length - 1 - index}`}
            onPress={() => tap(item.id)}
            onLongPress={() => setMenu(item.id)}
            style={{ alignSelf: item.mine ? 'flex-end' : 'flex-start', maxWidth: '80%', marginVertical: 4 }}
          >
            <View style={{ backgroundColor: item.mine ? c.accent : c.card, borderRadius: 16, padding: 10 }}>
              <Text style={{ color: item.mine ? c.accentText : c.text }}>{item.text}</Text>
            </View>
            {item.heart ? <Text style={{ alignSelf: item.mine ? 'flex-end' : 'flex-start' }}>❤️ Loved</Text> : null}
          </Pressable>
        )}
      />
      <ScrollView horizontal showsHorizontalScrollIndicator={false} keyboardShouldPersistTaps="handled" style={{ flexGrow: 0 }} contentContainerStyle={{ paddingHorizontal: 12 }}>
        {QUICK.map((q) => <Chip key={q} testID={`quick-${q}`} label={q} selected={false} onPress={() => send(q)} />)}
      </ScrollView>
      <View style={{ flexDirection: 'row', padding: 8, paddingBottom: 8 + insets.bottom, gap: 8, borderTopWidth: 1, borderColor: c.border }}>
        <TextInput
          testID="message-input"
          placeholder="Message"
          placeholderTextColor={c.muted}
          value={text}
          onChangeText={setText}
          onSubmitEditing={() => send(text)}
          returnKeyType="send"
          style={{ flex: 1, borderWidth: 1, borderColor: c.border, borderRadius: 20, paddingHorizontal: 14, paddingVertical: 8, color: c.text }}
        />
        <Pressable testID="send" accessibilityRole="button" accessibilityState={{ disabled: !text.trim() }} disabled={!text.trim()} onPress={() => send(text)} style={{ justifyContent: 'center', opacity: text.trim() ? 1 : 0.4 }}>
          <Text style={{ color: c.accent, fontWeight: '700', fontSize: 16 }}>Send</Text>
        </Pressable>
      </View>
      {menu !== null ? (
        <View style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, justifyContent: 'center', padding: 40 }}>
          {/* The backdrop beside the menu, not around it: on Android a tap on a button inside
              the backdrop's Pressable closed the menu without pressing the button. */}
          <Pressable testID="menu-backdrop" accessibilityLabel="Close menu" onPress={() => setMenu(null)} style={{ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, backgroundColor: 'rgba(0,0,0,0.3)' }} />
          <View style={[s.card, { backgroundColor: c.bg }]}>
            <Pressable testID="menu-copy" accessibilityRole="button" style={s.row} onPress={() => { setMenu(null); toast('Copied'); }}>
              <Text style={{ color: c.text, fontSize: 17 }}>Copy</Text>
            </Pressable>
            <Pressable testID="menu-delete" accessibilityRole="button" style={s.row} onPress={() => { setMessages((m) => m.filter((x) => x.id !== menu)); setMenu(null); }}>
              <Text style={{ color: c.danger, fontSize: 17 }}>Delete</Text>
            </Pressable>
          </View>
        </View>
      ) : null}
    </KeyboardAvoidingView>
  );
}

function Typing({ name }: { name: string }) {
  const c = useColors();
  return (
    <View accessible accessibilityLabel={`${name} is typing`} testID="typing" style={{ flexDirection: 'row', gap: 4, padding: 12, alignSelf: 'flex-start', backgroundColor: c.card, borderRadius: 16 }}>
      {[0, 1, 2].map((i) => <Dot key={i} i={i} />)}
    </View>
  );
}

function Dot({ i }: { i: number }) {
  const c = useColors();
  const y = useSharedValue(0);
  useEffect(() => {
    y.value = withDelay(i * 150, withRepeat(withSequence(withTiming(-6, { duration: 300 }), withTiming(0, { duration: 300 })), -1));
  }, [i, y]);
  const bounce = useAnimatedStyle(() => ({ transform: [{ translateY: y.value }] }));
  return <Animated.View style={[{ width: 8, height: 8, borderRadius: 4, backgroundColor: c.muted }, bounce]} />;
}
