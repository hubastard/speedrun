const { defineConfig } = require('cypress')

// The app's own Cypress settings: its URL and viewport.
module.exports = defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    specPattern: 'e2e/**/*.cy.js',
    supportFile: false,
    viewportWidth: 1280,
    viewportHeight: 1000,
  },
})
