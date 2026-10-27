// Deterministic content: the same products, posts and chats on every run and platform.

function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const ADJECTIVES = ['Trail', 'City', 'Classic', 'Urban', 'Studio', 'Coastal', 'Alpine', 'Retro', 'Daily', 'Weekend'];
const NOUNS = ['Sneaker', 'Backpack', 'Jacket', 'Watch', 'Cap', 'Hoodie', 'Bottle', 'Lamp', 'Notebook', 'Headphones'];
export const CATEGORIES = ['All', 'Shoes', 'Bags', 'Clothing', 'Tech', 'Home', 'Outdoor', 'Office', 'Gifts'];
const NOUN_CATEGORY: Record<string, string> = {
  Sneaker: 'Shoes', Backpack: 'Bags', Jacket: 'Clothing', Watch: 'Tech', Cap: 'Clothing',
  Hoodie: 'Clothing', Bottle: 'Outdoor', Lamp: 'Home', Notebook: 'Office', Headphones: 'Tech',
};
export const SIZES = ['S', 'M', 'L', 'XL'];
export const COLORS = ['Black', 'Blue', 'Red'];

export type Product = { id: number; name: string; price: number; category: string; rating: number; reviews: number };

export const PRODUCTS: Product[] = (() => {
  const r = rng(7);
  return Array.from({ length: 60 }, (_, i) => {
    const noun = NOUNS[i % NOUNS.length];
    const name = `${ADJECTIVES[Math.floor(i / NOUNS.length) % ADJECTIVES.length]} ${noun}`;
    return {
      id: i + 1,
      name,
      price: Math.round(15 + r() * 185) + 0.99,
      category: NOUN_CATEGORY[noun],
      rating: Math.round((3 + r() * 2) * 10) / 10,
      reviews: Math.floor(r() * 900),
    };
  });
})();

export function product(id: number): Product {
  return PRODUCTS[(id - 1 + PRODUCTS.length) % PRODUCTS.length];
}

export function money(n: number): string {
  return `$${n.toFixed(2)}`;
}

const AUTHORS = ['Maya', 'Leo', 'Ava', 'Noah', 'Zoe', 'Liam', 'Emma', 'Omar', 'Chloe', 'Hugo', 'Ines', 'Sam'];
const TOPICS = [
  'Morning run along the river', 'Tried the new ramen place', 'Finished my first marathon',
  'Rainy day reading list', 'Weekend hike with friends', 'Homemade pizza night',
  'Sunset from the rooftop', 'New desk setup', 'Concert last night', 'Garden update',
];

export type Post = { id: number; author: string; text: string; likes: number; comments: number; live: boolean };

export function posts(from: number, count: number): Post[] {
  return Array.from({ length: count }, (_, k) => {
    const id = from + k;
    const r = rng(id * 31);
    return {
      id,
      author: AUTHORS[id % AUTHORS.length],
      text: `Post ${id}: ${TOPICS[id % TOPICS.length]}`,
      likes: Math.floor(r() * 300),
      comments: Math.floor(r() * 40),
      live: id === 3,
    };
  });
}

export const STORIES = AUTHORS.slice(0, 10);

export type Chat = { id: string; name: string; last: string; unread: number };
export const CHATS: Chat[] = [
  { id: 'bot', name: 'Support Bot', last: 'Ask me anything', unread: 1 },
  ...AUTHORS.map((name, i) => ({
    id: name.toLowerCase(),
    name,
    last: TOPICS[(i + 3) % TOPICS.length],
    unread: i % 3 === 0 ? i + 1 : 0,
  })),
];
