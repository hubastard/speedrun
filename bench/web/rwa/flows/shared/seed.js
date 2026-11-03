// The app's own reset: its database back to the seed data.
http.post('http://localhost:3001/testData/seed', { body: '' })
