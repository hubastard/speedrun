import { test, expect, type Page } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('http://localhost:3001/testData/seed');
});

async function signIn(page: Page) {
  await page.goto('/signin');
  await page.locator('#username').fill('Heath93');
  await page.locator('#password').fill('s3cret');
  await page.locator('[data-test=signin-submit]').click();
  await expect(page.getByText('Ted P', { exact: true })).toBeVisible();
}

test('Sign in and out', async ({ page }) => {
  await signIn(page);
  await expect(page.getByText('$1,509.53')).toBeVisible();
  await page.locator('[data-test=sidenav-signout]').click();
  await expect(page.locator('#username')).toBeVisible();
});

test('Sign up, sign in, onboarding', async ({ page }) => {
  await page.goto('/signup');
  await page.locator('#firstName').fill('Bob');
  await page.locator('#lastName').fill('Ross');
  await page.locator('#username').fill('PainterJoy90');
  await page.locator('#password').fill('s3cret');
  await page.locator('#confirmPassword').fill('s3cret');
  await page.locator('[data-test=signup-submit]').click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.locator('#username').fill('PainterJoy90');
  await page.locator('#password').fill('s3cret');
  await page.locator('[data-test=signin-submit]').click();
  await expect(page.getByText('Get Started with Real World App')).toBeVisible();
  await page.locator('[data-test=user-onboarding-next]').click();
  await expect(page.getByText('Create Bank Account')).toBeVisible();
  await page.locator('#bankaccount-bankName-input').fill('The Best Bank');
  await page.locator('#bankaccount-routingNumber-input').fill('987654321');
  await page.locator('#bankaccount-accountNumber-input').fill('123456789');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Finished')).toBeVisible();
  await page.locator('[data-test=user-onboarding-next]').click();
  await expect(page.getByText('Finished')).not.toBeVisible();
  await page.locator('[data-test=sidenav-signout]').click();
  await expect(page.locator('#username')).toBeVisible();
});

test('Send a payment', async ({ page }) => {
  await signIn(page);
  await page.getByText('New', { exact: true }).click();
  await page.locator('#user-list-search-input').fill('Kristian');
  await page.getByText('Kristian Bradtke').click();
  await page.locator('#amount').fill('35');
  await page.locator('#transaction-create-description-input').fill('Sushi dinner');
  await page.getByRole('button', { name: 'Pay' }).click();
  await expect(page.getByText('Transaction Submitted!')).toBeVisible();
  await expect(page.getByText('$1,474.53')).toBeVisible();
  await page.getByText('Return To Transactions').click();
  await page.getByText('Mine', { exact: true }).click();
  await expect(page.getByText('Sushi dinner')).toBeVisible();
});

test('Request money', async ({ page }) => {
  await signIn(page);
  await page.getByText('New', { exact: true }).click();
  await page.getByText('Kristian Bradtke').click();
  await page.locator('#amount').fill('95');
  await page.locator('#transaction-create-description-input').fill('Fancy Hotel');
  await page.getByRole('button', { name: 'Request' }).click();
  await expect(page.getByText('Transaction Submitted!')).toBeVisible();
  await page.getByText('Return To Transactions').click();
  await page.getByText('Mine', { exact: true }).click();
  await expect(page.getByText('Fancy Hotel')).toBeVisible();
});

test('Like and comment on a transaction', async ({ page }) => {
  await signIn(page);
  await page.getByText('Mine', { exact: true }).click();
  await page.locator('[data-test^=transaction-item]').first().click();
  await expect(page.getByText('Transaction Detail')).toBeVisible();
  await page.locator('[data-test^=transaction-like-button]').click();
  await expect(page.locator('[data-test^=transaction-like-count]')).toHaveText('2');
  await page.locator('[id^=transaction-comment-input-]').fill('Thank you!');
  await page.locator('[id^=transaction-comment-input-]').press('Enter');
  await expect(page.getByText('Thank you!')).toBeVisible();
  await page.locator('[id^=transaction-comment-input-]').fill('Appreciate it.');
  await page.locator('[id^=transaction-comment-input-]').press('Enter');
  await expect(page.getByText('Appreciate it.')).toBeVisible();
});

test('Edit user settings', async ({ page }) => {
  await signIn(page);
  await page.getByText('My Account').click();
  await page.locator('#user-settings-firstName-input').fill('New First Name');
  await page.locator('#user-settings-lastName-input').fill('New Last Name');
  await page.locator('#user-settings-email-input').fill('email@email.com');
  await page.locator('#user-settings-phoneNumber-input').fill('6155551212');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('New First Name N', { exact: true })).toBeVisible();
});

test('Add a bank account', async ({ page }) => {
  await signIn(page);
  await page.getByText('Bank Accounts').click();
  await page.getByText('Create', { exact: true }).click();
  await page.locator('#bankaccount-bankName-input').fill('The Best Bank');
  await page.locator('#bankaccount-routingNumber-input').fill('987654321');
  await page.locator('#bankaccount-accountNumber-input').fill('123456789');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('The Best Bank')).toBeVisible();
});
