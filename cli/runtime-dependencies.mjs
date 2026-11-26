import { createRequire } from 'node:module';
import path from 'node:path';

export const resolveRuntimeDependency = (packageRoot, packageName) => {
  const requireFromPackage = createRequire(path.join(packageRoot, 'package.json'));
  return path.dirname(requireFromPackage.resolve(`${packageName}/package.json`));
};
