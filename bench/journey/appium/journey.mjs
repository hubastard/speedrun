// The journey (../journey.yaml) with Appium and WebdriverIO, written as Appium tests usually
// are: an element per step, waitForDisplayed() before acting, click() and setValue(), and the
// platform's own selectors (UiAutomator on Android, class chains on iOS).
// An Appium server must be running (run.sh starts one); run.sh resets the app's data before
// each run.
//   node journey.mjs android|ios [device]
import { remote } from 'webdriverio';

const platform = process.argv[2];
const device = process.argv[3];
const APP = 'dev.speedrun.bench';
const android = platform === 'android';
if (!['android', 'ios'].includes(platform)) throw new Error('usage: node journey.mjs android|ios [device]');

// The session launches the app (and on iOS waits for it to go idle before each action).
const start = Date.now();
const driver = await remote({
  hostname: '127.0.0.1',
  port: 4723,
  logLevel: 'error',
  waitforTimeout: 15000,
  capabilities: android
    ? { platformName: 'Android', 'appium:automationName': 'UiAutomator2', 'appium:appPackage': APP,
        'appium:appActivity': '.MainActivity', 'appium:noReset': true, 'appium:newCommandTimeout': 300,
        ...(device && { 'appium:udid': device }) }
    : { platformName: 'iOS', 'appium:automationName': 'XCUITest', 'appium:bundleId': APP,
        'appium:noReset': true, 'appium:newCommandTimeout': 300, ...(device && { 'appium:udid': device }) },
});

// The element with this testID, and the element showing this text: the first one (React
// Native on iOS reports a text twice, its container and the text).
const id = (s) => driver.$(android ? `android=new UiSelector().resourceId("${s}").instance(0)`
  : `-ios class chain:**/*[\`name == "${s}"\`][1]`);
const text = (s) => driver.$(android ? `android=new UiSelector().text("${s}").instance(0)`
  : `-ios class chain:**/*[\`label == "${s}" OR value == "${s}"\`][1]`);

async function tap(el) {
  await el.waitForDisplayed();
  await el.click();
}
async function see(el) {
  await el.waitForDisplayed();
}
async function type(el, value) {
  await el.waitForDisplayed();
  await el.setValue(value);
}
// Swipes up until the element is displayed (rows of a long list are created as it scrolls).
async function scrollTo(el) {
  for (let i = 0; i < 30 && !(await el.isDisplayed()); i++) {
    const { width, height } = await driver.getWindowSize();
    await driver.action('pointer', { parameters: { pointerType: 'touch' } })
      .move({ x: Math.round(width / 2), y: Math.round(height * 0.7) }).down()
      .move({ x: Math.round(width / 2), y: Math.round(height * 0.3), duration: 300 }).up().perform();
  }
  await el.waitForDisplayed();
}

async function journey() {
  // Sign in with a phone number and a code.
  await tap(id('onboarding-skip'));
  await type(id('phone-input'), '5550101234');
  await tap(id('next'));
  await type(id('code-input'), '123456');
  await tap(id('notify-later'));
  await see(text('Hi, Alex'));

  // Search the shop, pick options, add to the cart.
  await tap(id('tab-shop'));
  await type(id('search-input'), 'sneaker');
  if (android) await driver.pressKeyCode(66); // Enter
  else await id('search-input').addValue('\n');
  await see(text('6 products'));
  await tap(text('City Sneaker'));
  await tap(id('size-M'));
  await tap(id('color-Blue'));
  await tap(id('qty-plus'));
  await see(text('Qty 2'));
  await tap(id('qty-plus'));
  await see(text('Qty 3'));
  await tap(id('add-to-cart'));
  await see(text('Cart (3)'));
  await tap(id('go-to-cart'));
  await see(text('Size M · Blue'));
  await tap(id('header-back'));
  await tap(id('header-back'));

  // Set a PIN on a keypad that a loading overlay covers for its first 1.5 s.
  await tap(id('tab-profile'));
  await tap(id('security'));
  // The first key, tapped until the dots show it: the overlay takes taps while it shows.
  const dots = async () => id('pin-dots').getAttribute(android ? 'content-desc' : 'label');
  for (let i = 0; i < 30 && (await dots()) !== '1 of 4 digits'; i++) {
    await tap(id('key-1'));
    if ((await dots()) !== '1 of 4 digits') await driver.pause(200);
  }
  for (const k of ['2', '3', '4']) await tap(id(`key-${k}`));
  await see(text('Confirm your PIN'));
  for (const k of ['1', '2', '3', '4']) await tap(id(`key-${k}`));
  await see(text('PIN set'));

  // Scroll a long list to a row and pick it.
  await tap(id('tab-lab'));
  await tap(id('lab-drag'));
  await tap(id('open-long-list'));
  await scrollTo(text('Row 60'));
  await tap(text('Row 60'));
  await see(text('Picked row 60'));

}

try {
  await journey();
  console.log(`JOURNEY_SECONDS ${((Date.now() - start) / 1000).toFixed(1)}`);
} catch (e) {
  // What was on screen.
  const src = await driver.getPageSource().catch(() => '');
  const labels = [...src.matchAll(android ? / text="([^"]+)"/g : / label="([^"]+)"/g)].map((m) => m[1]);
  console.error(`FAILED: ${e.message}\non screen: ${labels.slice(0, 80).join(' | ')}`);
  process.exitCode = 1;
}
await driver.deleteSession();
