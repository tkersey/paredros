const group = (count, ...filters) => ({count, filters});

const suites = {
  authority: {
    driver: group(21, 'native_authority_test.', 'tests.native_driver.', 'tests.native_daemon.'),
    proposal: group(2, 'control proposal consumer shows and confirms maximal retained body',
      'control proposal consumer confirms each proposal once'),
    controls: group(75, 'tests.native_session.', 'control CLI preserves', 'control CLI repeats', 'control reads messages', 'control protocol freezes',
      'control pages pending', 'control malformed and unsupported', 'control task show reports', 'tests.control_socket.', 'tests.index.',
      'tests.messages.', 'tests.contracts.', 'tests.native_genesis.', 'tests.application.'),
  },
  providers: 31,
  'transitions-first': 13,
  'transitions-second': 17,
  'transitions-third': 12,
  rendering: {
    frames: group(4, 'native_rendering_test.', 'native render frame retains truthful',
      'native render frame safely abbreviates', 'native render frame drops absent'),
    escaping: group(2, 'native render frame budgets hostile escaping', 'native render frame neutralizes'),
    proposal: group(1, 'native conversation retains maximal exact proposal body'),
    multibyte: group(1, 'native conversation retains full multibyte'),
    publication: group(15, 'native render frame keeps Unicode', 'native render frame empty evidence',
      'native conversation describes exact hostile Unicode', 'native conversation describes neutralized',
      'tests.native_check_publish.', 'tests.native_step.'),
    bytes: group(4, 'native ordinary render chooses an exact', 'native ordinary render bounds its exact',
      'native ordinary render bounds its prefix'),
    coverage: group(5, 'native ordinary render keeps oversized', 'native ordinary render stops at an accepted gap',
      'native ordinary render rejects incomplete', 'native ordinary render preserves empty', 'native ordinary render leaves an unknown'),
    model: group(2, 'native ordinary render calls one model', 'native ordinary render makes context exhaustion'),
    rejection: group(1, 'native ordinary render never retries'),
    faults: group(3, 'native retained render before-call fault', 'native retained render after-call fault',
      'native retained render source mismatch'),
    retained: group(4, 'native retained render updates bounded state', 'native retained render preserves whole oversized',
      'native retained render reserves method state', 'native retained render discards crowding state'),
    conversation: group(20, 'native conversation turn binds', 'native conversation final failure',
      'native conversation refuses', 'tests.native_authoring.', 'tests.native_genesis.', 'tests.contracts.', 'tests.render.',
      'tests.native_method.', 'tests.method.', 'tests.step.', 'tests.check_publish.', 'tests.render_frame.'),
  },
  methods: {
    campaign: group(1, 'native experiment compares all cases'),
    qualification: group(20, 'native experiment rejects missing', 'native experiment codec owns', 'native experiment reaches scripted',
      'native_methods_test.', 'tests.native_method.', 'tests.method_catalog.', 'tests.method.',
      'tests.experiment.', 'tests.native_genesis.', 'tests.contracts.'),
  },
  'continuity-first': 33,
  'continuity-second': 11,
  'continuity-third': 9,
  product: 5,
  crash: 8,
};

const include = [];
for (const [part, suite] of Object.entries(suites)) {
  if (typeof suite === 'number') {
    include.push({part, name: part, count: suite});
    continue;
  }
  const groups = Object.values(suite);
  const filters = groups.map(group => group.filters);
  const inventory = groups.reduce((total, group) => total + group.count, 0);
  for (const [index, name] of Object.keys(suite).entries()) {
    include.push({part, name: part + '-' + name, count: groups[index].count, inventory, filters, index});
  }
}
console.log(JSON.stringify({include}));
