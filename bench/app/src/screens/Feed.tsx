// Home: a news ticker sliding forever, stories (the first ring spinning), a skeleton while
// the feed loads, a promo banner that pushes the feed down once it arrives, posts liked with
// a button or a double tap, pull to refresh, and more posts loaded at the end.
import React, { useEffect, useRef, useState } from 'react';
import { FlatList, Pressable, RefreshControl, ScrollView, Text, View } from 'react-native';
import Animated, {
  Easing, useAnimatedStyle, useSharedValue, withRepeat, withSequence, withSpring, withTiming,
} from 'react-native-reanimated';

import { Post, posts, STORIES } from '../data';
import { useStore } from '../store';
import { Body, Header, Marquee, Pulse, s, Shimmer, Spinner, useColors } from '../ui';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

const PAGE = 20;
const MAX_POSTS = 200;

export function Feed() {
  const c = useColors();
  const insets = useSafeAreaInsets();
  const name = useStore((st) => st.name);
  const [loading, setLoading] = useState(true);
  const [items, setItems] = useState<Post[]>([]);
  const [more, setMore] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshes, setRefreshes] = useState(0);
  const [promo, setPromo] = useState(false);
  const loadingMore = useRef(false);

  useEffect(() => {
    const t1 = setTimeout(() => {
      setItems(posts(1, PAGE));
      setLoading(false);
    }, 1200);
    const t2 = setTimeout(() => setPromo(true), 2700);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, []);

  function loadMore() {
    if (loadingMore.current || loading || items.length >= MAX_POSTS) return;
    loadingMore.current = true;
    setMore(true);
    setTimeout(() => {
      setItems((cur) => [...cur, ...posts(cur.length + 1, PAGE)]);
      setMore(false);
      loadingMore.current = false;
    }, 800);
  }

  const top = (
    <View>
      <Marquee testID="announcement" text="Free shipping on orders over $50   ·   New arrivals every Friday   ·   Invite friends and earn rewards   ·   Free shipping on orders over $50" />
      <ScrollView testID="stories" horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ padding: 12, gap: 12 }}>
        {STORIES.map((n, i) => <Story key={n} name={n} spinning={i === 0} />)}
      </ScrollView>
      {promo ? <Promo /> : null}
      <Text testID="refresh-count" style={{ color: c.muted, paddingHorizontal: 16 }}>{refreshes ? `Refreshed ${refreshes}×` : `Hi, ${name}`}</Text>
    </View>
  );

  return (
    <View style={{ flex: 1, backgroundColor: c.bg, paddingTop: insets.top }}>
      <Header title="Home" back={false} />
      {loading ? (
        <View>
          {top}
          <View testID="feed-skeleton" accessible accessibilityLabel="Loading feed" style={{ padding: 16 }}>
            {[0, 1, 2].map((k) => (
              <View key={k} style={[s.card, { backgroundColor: c.card }]}>
                <Shimmer width="40%" />
                <Shimmer height={120} />
                <Shimmer width="70%" />
              </View>
            ))}
          </View>
        </View>
      ) : (
        <FlatList
          testID="feed"
          data={items}
          keyExtractor={(p) => String(p.id)}
          ListHeaderComponent={top}
          renderItem={({ item }) => <PostCard post={item} />}
          onEndReachedThreshold={0.5}
          onEndReached={loadMore}
          ListFooterComponent={more ? <Spinner label="Loading more" /> : <View style={{ height: 40 }} />}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={() => {
                setRefreshing(true);
                setTimeout(() => {
                  setRefreshing(false);
                  setRefreshes((n) => n + 1);
                }, 1000);
              }}
            />
          }
        />
      )}
    </View>
  );
}

function Story({ name, spinning }: { name: string; spinning: boolean }) {
  const c = useColors();
  const r = useSharedValue(0);
  useEffect(() => {
    if (spinning) r.value = withRepeat(withTiming(360, { duration: 2000, easing: Easing.linear }), -1);
  }, [r, spinning]);
  const spin = useAnimatedStyle(() => ({ transform: [{ rotate: `${r.value}deg` }] }));
  return (
    <View style={{ alignItems: 'center', width: 64 }}>
      <View style={{ width: 60, height: 60, alignItems: 'center', justifyContent: 'center' }}>
        <Animated.View style={[{ position: 'absolute', width: 60, height: 60, borderRadius: 30, borderWidth: 3, borderColor: c.accent, borderTopColor: '#f59e0b' }, spin]} />
        <View style={{ width: 48, height: 48, borderRadius: 24, backgroundColor: c.card, alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ color: c.text, fontWeight: '700' }}>{name[0]}</Text>
        </View>
      </View>
      <Text testID={`story-${name}`} style={{ color: c.text, fontSize: 12, marginTop: 4 }}>{name}</Text>
    </View>
  );
}

function Promo() {
  const c = useColors();
  const h = useSharedValue(0);
  useEffect(() => {
    h.value = withTiming(96, { duration: 350 });
  }, [h]);
  const grow = useAnimatedStyle(() => ({ height: h.value }));
  return (
    <Animated.View testID="promo-banner" style={[{ marginHorizontal: 16, marginBottom: 8, borderRadius: 14, backgroundColor: c.accent, overflow: 'hidden', justifyContent: 'center', paddingHorizontal: 16 }, grow]}>
      <Text style={{ color: c.accentText, fontSize: 18, fontWeight: '800' }}>Summer sale: 20% off</Text>
      <Text style={{ color: c.accentText }}>On everything in the shop this week</Text>
    </Animated.View>
  );
}

function PostCard({ post }: { post: Post }) {
  const c = useColors();
  const [liked, setLiked] = useState(false);
  const lastTap = useRef(0);
  const heart = useSharedValue(0);
  const pop = useAnimatedStyle(() => ({ opacity: heart.value, transform: [{ scale: 0.6 + heart.value * 0.6 }] }));
  function like(v: boolean) {
    setLiked(v);
    if (v) heart.value = withSequence(withSpring(1), withTiming(0, { duration: 400 }));
  }
  return (
    <View testID={`post-${post.id}`} style={[s.card, { backgroundColor: c.card, marginHorizontal: 16 }]}>
      <View style={{ flexDirection: 'row', alignItems: 'center', marginBottom: 8 }}>
        <Text style={{ color: c.text, fontWeight: '700', flex: 1 }}>{post.author}</Text>
        {post.live ? (
          <Pulse style={{ backgroundColor: c.danger, borderRadius: 6, paddingHorizontal: 8, paddingVertical: 2 }}>
            <Text style={{ color: '#fff', fontWeight: '800', fontSize: 12 }}>LIVE</Text>
          </Pulse>
        ) : null}
      </View>
      <Body>{post.text}</Body>
      <Pressable
        testID={`photo-${post.id}`}
        accessibilityLabel={`Photo of post ${post.id}`}
        onPress={() => {
          const now = Date.now();
          if (now - lastTap.current < 350) {
            like(true);
            lastTap.current = 0;
          } else lastTap.current = now;
        }}
        style={{ height: 140, borderRadius: 10, backgroundColor: c.border, marginVertical: 10, alignItems: 'center', justifyContent: 'center' }}
      >
        <Animated.Text style={[{ fontSize: 64, color: '#ef4444' }, pop]}>♥</Animated.Text>
      </Pressable>
      <View style={{ flexDirection: 'row', alignItems: 'center' }}>
        <Pressable testID={`like-${post.id}`} accessibilityRole="button" accessibilityState={{ selected: liked }} onPress={() => like(!liked)} hitSlop={8}>
          <Text style={{ color: liked ? c.danger : c.text, fontWeight: '700' }}>{liked ? `Liked · ${post.likes + 1}` : `Like · ${post.likes}`}</Text>
        </Pressable>
        <Text style={{ color: c.muted, marginLeft: 16 }}>{`${post.comments} comments`}</Text>
      </View>
    </View>
  );
}
