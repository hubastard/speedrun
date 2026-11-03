const TODOS = ['Buy milk', 'Walk the dog', 'Write report', 'Call mom', 'Book flights']

it('Add, complete, filter and clear todos', () => {
  cy.visit('/')
  for (const t of TODOS) cy.get('.new-todo').type(`${t}{enter}`)
  cy.contains('li', 'Walk the dog').find('.toggle').check()
  cy.contains('4 items left').should('be.visible')
  cy.contains('a', 'Active').click()
  cy.contains('Walk the dog').should('not.exist')
  cy.contains('a', 'Completed').click()
  cy.contains('Walk the dog').should('be.visible')
  cy.contains('Buy milk').should('not.exist')
  cy.contains('button', 'Clear completed').click()
  cy.contains('a', 'All').click()
  cy.contains('4 items left').should('be.visible')
  cy.contains('Walk the dog').should('not.exist')
})
