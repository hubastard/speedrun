const { defineConfig } = require('cypress')

// Playwright's default viewport, as the other tools use here.
module.exports = defineConfig({
  e2e: {
    baseUrl: 'http://127.0.0.1:8791',
    specPattern: 'e2e/**/*.cy.js',
    supportFile: false,
    viewportWidth: 1280,
    viewportHeight: 720,
  },
})
