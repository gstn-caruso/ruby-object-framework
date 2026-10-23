import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { analyzeCommits } from "@semantic-release/commit-analyzer";
import { generateNotes } from "@semantic-release/release-notes-generator";

const config = JSON.parse(readFileSync(new URL("../.releaserc.json", import.meta.url)));
const optionsFor = (name) => config.plugins.find((plugin) => plugin[0] === name)[1];
const logger = { log() {} };
const commits = (messages) => messages.map((message, index) => ({ message, hash: `${index}`.padStart(40, "0") }));

for (const [message, expected] of [
  ["fix: preserve request deadlines", "patch"],
  ["feat: support another adapter", "minor"],
  ["feat!: change the invocation protocol", "major"],
  ["fix: change errors\n\nBREAKING CHANGE: callers must handle a new error", "major"],
  ["docs: explain installation", "patch"],
  ["chore: update dependencies", "patch"],
  ["Merge pull request #42 from feature/packaging", "patch"],
]) {
  test(`${message.split("\n")[0]} produces a ${expected} release`, async () => {
    assert.equal(await analyzeCommits(optionsFor("@semantic-release/commit-analyzer"), {
      cwd: process.cwd(), logger, commits: commits([message]),
    }), expected);
  });
}

test("the highest semantic change wins across the merged commits", async () => {
  assert.equal(await analyzeCommits(optionsFor("@semantic-release/commit-analyzer"), {
    cwd: process.cwd(), logger, commits: commits(["docs: install", "feat: add storage", "fix!: change errors"]),
  }), "major");
});

test("an already released checkout does not produce another version", async () => {
  assert.equal(await analyzeCommits(optionsFor("@semantic-release/commit-analyzer"), {
    cwd: process.cwd(), logger, commits: [],
  }), null);
});

test("documentation-only releases include their changes in the release notes", async () => {
  const notes = await generateNotes(optionsFor("@semantic-release/release-notes-generator"), {
    cwd: process.cwd(), logger,
    options: { repositoryUrl: "https://github.com/gstn-caruso/ruby-object-framework.git" },
    commits: commits(["docs: explain gem installation"]),
    lastRelease: { gitTag: "v1.0.0" }, nextRelease: { gitTag: "v1.0.1", version: "1.0.1" },
  });
  assert.match(notes, /explain gem installation/);
});

test("releases keep the gem, main, lockfile, and tags aligned and do not repeat without new commits", async () => {
  const directory = mkdtempSync(join(tmpdir(), "object-framework-release-"));
  const cwd = join(directory, "checkout");
  const remote = join(directory, "origin.git");
  const root = fileURLToPath(new URL("..", import.meta.url));
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("GITHUB_") && name !== "CI"));
  const git = (...args) => execFileSync("git", args, { cwd, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  const plugins = config.plugins.filter(([name]) => name !== "@semantic-release/github").map(([name, options]) => [
    fileURLToPath(import.meta.resolve(name)),
    name === "@semantic-release/exec" ? {
      ...options, publishCmd: "test -f pkg/ruby-object-framework-${nextRelease.version}.gem",
    } : options,
  ]);
  const release = () => execFileSync(process.execPath, [join(root, "node_modules/semantic-release/bin/semantic-release.js"), "--no-ci"],
    { cwd, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

  try {
    mkdirSync(join(cwd, "tools"), { recursive: true });
    for (const path of ["lib", "ruby-object-framework.gemspec", "Gemfile", "Gemfile.lock", "tools/prepare_release.rb", ".ruby-version", ".tool-versions"]) {
      cpSync(join(root, path), join(cwd, path), { recursive: true });
    }
    writeFileSync(join(cwd, ".releaserc.json"), JSON.stringify({
      branches: config.branches, tagFormat: config.tagFormat,
      repositoryUrl: pathToFileURL(remote).href, plugins,
    }));
    git("init", "--bare", "--initial-branch=main", remote);
    git("init", "--initial-branch=main");
    git("config", "user.name", "Release test");
    git("config", "user.email", "release@example.test");
    git("add", ".");
    git("commit", "-m", "feat: package the framework");
    git("remote", "add", "origin", pathToFileURL(remote).href);
    git("push", "--set-upstream", "origin", "main");

    for (const version of ["1.0.0", "1.0.1"]) {
      release();
      assert.match(git("show", `v${version}:lib/object_framework/version.rb`), new RegExp(`VERSION = "${version.replaceAll(".", "\\.")}"`));
      assert.ok(git("show", `v${version}:Gemfile.lock`).includes(`ruby-object-framework (${version})`));
      assert.equal(git("rev-parse", `v${version}`), git("ls-remote", "origin", "refs/heads/main").split(/\s/)[0]);
      const archiveVersion = execFileSync("ruby", ["-rrubygems/package", "-e",
        "puts Gem::Package.new(ARGV.fetch(0)).spec.version", `pkg/ruby-object-framework-${version}.gem`],
      { cwd, env, encoding: "utf8" }).trim();
      assert.equal(archiveVersion, version);
      assert.equal(git("log", "-1", "--format=%s"), `chore(release): ${version} [skip ci]`);
      const tags = git("tag", "--list");
      release();
      assert.equal(git("tag", "--list"), tags);

      if (version === "1.0.0") {
        writeFileSync(join(cwd, "README.md"), "Installation instructions\n");
        git("add", "README.md");
        git("commit", "-m", "docs: explain gem installation");
        git("push", "origin", "main");
      }
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
