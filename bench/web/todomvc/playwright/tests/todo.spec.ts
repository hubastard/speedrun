import { test, expect } from '@playwright/test';

const TODOS = ['Buy milk', 'Walk the dog', 'Write report', 'Call mom', 'Book flights'];

test('Add, complete, filter and clear todos', async ({ page }) => {
  await page.goto('/');
  const input = page.getByPlaceholder('What needs to be done?');
  for (const t of TODOS) {
    await input.fill(t);
    await input.press('Enter');
  }
  await page.getByRole('listitem').filter({ hasText: 'Walk the dog' }).getByRole('checkbox').check();
  await expect(page.getByText('4 items left')).toBeVisible();
  await page.getByRole('link', { name: 'Active' }).click();
  await expect(page.getByText('Walk the dog')).toBeHidden();
  await page.getByRole('link', { name: 'Completed' }).click();
  await expect(page.getByText('Walk the dog')).toBeVisible();
  await expect(page.getByText('Buy milk')).toBeHidden();
  await page.getByRole('button', { name: 'Clear completed' }).click();
  await page.getByRole('link', { name: 'All' }).click();
  await expect(page.getByText('4 items left')).toBeVisible();
  await expect(page.getByText('Walk the dog')).toBeHidden();
});
