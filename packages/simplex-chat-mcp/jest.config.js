const project = {
  rootDir: __dirname,
  preset: "ts-jest",
  testEnvironment: "node",
  transform: {
    "^.+\\.ts$": ["ts-jest", {tsconfig: "test/tsconfig.json", diagnostics: {ignoreCodes: [151002]}}]
  }
}

module.exports = {
  maxWorkers: 1,
  testTimeout: 30000,
  projects: [
    {...project, displayName: "unit", testMatch: ["<rootDir>/test/unit/**/*.test.ts"], globalSetup: "<rootDir>/test/unit/home.ts"},
    {...project, displayName: "e2e", testMatch: ["<rootDir>/test/e2e/**/*.test.ts"]}
  ]
}
