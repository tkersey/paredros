const group = (count, ...filters) => ({count, filters});

const suites = {
  authority: {
    driver: group(20, 'native_authority_test.', 'tests.native_driver.', 'tests.native_delivery_retirement.', 'tests.native_daemon.'),
    proposal: group(1, 'control proposal consumer shows and confirms maximal retained body'),
    controls: group(78, 'tests.native_session.', 'control CLI preserves', 'control protocol freezes',
      'control pages pending', 'control malformed and unsupported', 'tests.control_socket.', 'tests.index.',
      'tests.outbound.', 'tests.history_evidence.', 'tests.delivery_fact.', 'tests.contracts.', 'tests.native_genesis.', 'tests.application.'),
  },
  providers: 40,
  'transitions-first': 15,
  'transitions-second': {
    receipts: group(1, 'native settlements retain deliveries with mismatched admissions or receipts'),
    coverage: group(1, 'native settlements retain deliveries with unproven coverage or inactive intent'),
    accounting: group(16, 'native_transitions_test.', 'tests.native_revision.', 'tests.revision.',
      'tests.settlement.', 'tests.native_genesis.', 'tests.contracts.', 'native settlements consume revisions',
      'native settlements reject repeated', 'native settlements check overflow', 'native settlements resolve exact',
      'native settlements require coherent'),
    delivery: group(4, 'native settlements advance only exact', 'native settlements hold unknown',
      'native settlements distinguish identical', 'native settlements use exclusive'),
    retry: group(4, 'native settlements retry only', 'native settlements preserve pacing',
      'native settlements retain paused', 'native settlements clear activation'),
  },
  'transitions-third': 11,
  rendering: {
    frames: group(4, 'native_rendering_test.', 'native render frame retains truthful',
      'native render frame safely abbreviates', 'native render frame drops absent'),
    escaping: group(1, 'native render frame budgets hostile escaping'),
    proposal: group(1, 'native conversation retains maximal exact proposal body'),
    multibyte: group(1, 'native conversation retains full multibyte'),
    publication: group(20, 'native render frame keeps Unicode', 'native render frame empty evidence',
      'native conversation describes exact hostile Unicode', 'tests.native_check_publish.', 'tests.native_audit.', 'tests.native_step.'),
    bytes: group(2, 'native ordinary render chooses an exact', 'native ordinary render includes raw capture'),
    coverage: group(5, 'native ordinary render keeps oversized', 'native ordinary render stops at an accepted gap',
      'native ordinary render rejects incomplete', 'native ordinary render preserves empty', 'native ordinary render leaves an unknown'),
    model: group(2, 'native ordinary render calls one model', 'native ordinary render makes context exhaustion'),
    rejection: group(1, 'native ordinary render never retries'),
    faults: group(3, 'native retained render before-call fault', 'native retained render after-call fault',
      'native retained render source mismatch'),
    retained: group(2, 'native retained render updates bounded state', 'native retained render preserves whole oversized'),
    conversation: group(21, 'native conversation turn binds', 'native conversation final failure',
      'native conversation refuses', 'tests.native_authoring.', 'tests.native_genesis.', 'tests.contracts.', 'tests.render.',
      'tests.native_method.', 'tests.method.', 'tests.step.', 'tests.check_publish.', 'tests.render_frame.'),
  },
  methods: {
    campaign: group(1, 'native experiment compares all cases'),
    qualification: group(20, 'native experiment rejects missing', 'native experiment codec owns', 'native experiment reaches scripted',
      'native_methods_test.', 'tests.native_method.', 'tests.method_catalog.', 'tests.method.',
      'tests.experiment.', 'tests.native_genesis.', 'tests.contracts.'),
  },
  'continuity-first': 7,
  'continuity-second': 21,
  'continuity-third': 13,
  product: 5,
  crash: 12,
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
