// Xcode 27 builds nothing for iOS below 15: some pods (Lottie's resource bundles) still
// declare 13. Raise every pod target to at least 15.1 in the Podfile's post_install.
const { withDangerousMod } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

const MARK = '# speedrun: pod deployment targets';
const SNIPPET = `
    ${MARK}
    installer.pods_project.targets.each do |t|
      t.build_configurations.each do |cfg|
        if cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f < 15.1
          cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.1'
        end
      end
    end
`;

module.exports = function withPodDeploymentTarget(config) {
  return withDangerousMod(config, [
    'ios',
    (cfg) => {
      const file = path.join(cfg.modRequest.platformProjectRoot, 'Podfile');
      let podfile = fs.readFileSync(file, 'utf8');
      if (!podfile.includes(MARK)) {
        podfile = podfile.replace(/post_install do \|installer\|\n/, (m) => m + SNIPPET);
        fs.writeFileSync(file, podfile);
      }
      return cfg;
    },
  ]);
};
