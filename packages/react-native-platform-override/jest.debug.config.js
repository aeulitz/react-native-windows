/**
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 *
 * @format
 * @ts-check
 */

// For a detailed explanation regarding each configuration property, visit:
// https://jestjs.io/docs/en/configuration.html

module.exports = {
  // A list of paths to directories that Jest should use to search for files in
  roots: ['<rootDir>/src/'],

  // The test environment that will be used for testing
  testEnvironment: 'node',

  // The pattern or patterns Jest uses to detect test files
  testRegex: '/(test|e2etest)/.*\\.test',

  // Default timeout of a test in milliseconds
  testTimeout: 600000,
};
