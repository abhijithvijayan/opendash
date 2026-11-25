const appName = 'OpenDash';
const appVersion = '0.3.2';
const repoUrl = 'github.com/abhijithvijayan/opendash';

/// Where OpenDash's own releases are published (`owner/repo` on GitHub).
/// It must be public: the app asks without a token.
const releasesRepo = 'abhijithvijayan/opendash';
/// Where the anonymous weekly usage ping goes (`server/usage`). Empty: none
/// is sent.
const usagePingUrl = 'https://opendash-usage.abhijithvijayan.workers.dev/v1/ping';
const ownPackage = 'in.abhijithvijayan.opendash';
const issuesUrl = '$repoUrl/issues';

/// The phone app that installs, updates and removes OpenDash, and sends it
/// updates when the scooter can't reach GitHub.
const companionRepoUrl = 'github.com/abhijithvijayan/opendash-companion';
const stockDashboardPackage = 'com.olaelectric.hmiclient';
const openHeadunitPackage = 'com.andrerinas.headunitrevived';
const diplayPackage = 'com.shihab.diplay';
