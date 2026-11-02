const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

// Execute the actual github-script body with an API stub, without a token or network.
const workflow = fs.readFileSync(path.join(__dirname, '../../.github/workflows/pr-issue-alignment.yml'), 'utf8');
const script = workflow.split('          script: |')[1]
    .split(/\r?\n/).map(line => line.replace(/^            /, '')).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('context', 'github', 'core', script);

async function review({ user, files, body = '', headRepo = 'ME-Massine/pulsestream', actor = 'ME-Massine' } = {}) {
    const failures = [];
    const messages = [];
    const comments = [];
    let pages = 0;
    const listFiles = () => { throw new Error('File listing must use pagination'); };
    const context = {
        actor,
        repo: { owner: 'ME-Massine', repo: 'pulsestream' },
        payload: { pull_request: {
            number: 367,
            user: user || { login: 'dependabot[bot]', type: 'Bot' },
            title: 'build(deps): bump dependency', body,
            head: { repo: { full_name: headRepo }, ref: 'dependabot/update' },
            base: { repo: { full_name: 'ME-Massine/pulsestream' } }
        } }
    };
    const github = {
        paginate: async (method, args) => {
            assert.equal(method, listFiles);
            assert.equal(args.pull_number, 367);
            assert.equal(args.per_page, 100);
            pages++;
            return files || [{ filename: 'services/ingestion-service/pom.xml', status: 'modified' }];
        },
        rest: {
            pulls: { listFiles },
            issues: {
                get: async () => ({ data: { title: 'Dependency maintenance', body: '' } }),
                listComments: async () => ({ data: [] }),
                createComment: async comment => comments.push(comment),
                updateComment: async () => { throw new Error('Unexpected comment update'); }
            }
        }
    };
    await run(context, github, { setFailed: message => failures.push(message), info: message => messages.push(message) });
    return { failures, messages, comments, pages };
}

test('Dependabot accepts configured manifests with a read-only token, even when a human reruns it', async () => {
    const paths = [
        'services/ingestion-service/pom.xml', 'services/query-service/pom.xml',
        'services/telemetry-processor/pom.xml', 'services/ingestion-service/Dockerfile',
        'services/query-service/Dockerfile', 'services/telemetry-processor/Dockerfile',
        'services/query-service/.mvn/wrapper/maven-wrapper.properties',
        '.github/workflows/ci.yml', 'infrastructure/docker/docker-compose.yml'
    ];
    const result = await review({ files: paths.map(filename => ({ filename, status: 'modified' })) });
    assert.deepEqual(result.failures, []);
    assert.equal(result.pages, 1);
    assert.equal(result.messages.length, 1);
    assert.deepEqual(result.comments, []);
});

test('Dependabot rejects source files, unknown paths, renames, removals and an empty diff', async () => {
    const badFiles = [
        [{ filename: 'services/ingestion-service/src/main/java/Controller.java', status: 'modified' }],
        [{ filename: '.github/dependabot.yml', status: 'modified' }],
        [{ filename: 'other/pom.xml', status: 'modified' }],
        [{ filename: 'services/query-service/pom.xml', status: 'renamed' }],
        [{ filename: 'services/query-service/pom.xml', status: 'removed' }],
        []
    ];
    for (const files of badFiles) {
        const result = await review({ files });
        assert.equal(result.failures.length, 1);
        assert.deepEqual(result.comments, []);
    }
});

test('Dependabot validates every file returned across pages', async () => {
    const files = Array.from({ length: 100 }, () => ({ filename: 'services/query-service/pom.xml', status: 'modified' }));
    files.push({ filename: 'scripts/deploy.ps1', status: 'modified' });
    assert.equal((await review({ files })).failures.length, 1);
});

test('Dependabot rejects an update from a different or missing repository', async () => {
    for (const headRepo of ['someone/pulsestream', null]) {
        assert.equal((await review({ headRepo })).failures.length, 1);
    }
});

test('Human and other bot PRs retain the template and issue requirements', async () => {
    for (const user of [
        { login: 'ME-Massine', type: 'User' },
        { login: 'other[bot]', type: 'Bot' },
        { login: 'dependabot[bot]', type: 'User' }
    ]) {
        const result = await review({ user, actor: 'dependabot[bot]' });
        assert.match(result.failures[0], /6 issue\(s\)/);
        assert.equal(result.comments.length, 1);
        assert.match(result.comments[0].body, /Missing linked issue/);
        assert.equal(result.pages, 0);
    }
});

test('A complete human PR with a linked issue still passes', async () => {
    const body = '## Summary\nUpdate dependencies.\n## Related Issue\nCloses #263\n## Changes\nVersion bumps.\n## Testing\nMaven verify.\n## Checklist\n- [x] Tests pass';
    const result = await review({ user: { login: 'ME-Massine', type: 'User' }, body });
    assert.deepEqual(result.failures, []);
    assert.equal(result.comments.length, 1);
    assert.match(result.comments[0].body, /No blocking alignment issues/);
});
