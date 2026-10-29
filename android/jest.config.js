module.exports = {
  preset: '@react-native/jest-preset',
  // Only *.test.* files are suites; __tests__/fixtures.ts is a shared helper.
  testMatch: ['**/__tests__/**/*.test.[jt]s?(x)'],
};
