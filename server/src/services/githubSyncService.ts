import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { logInfo, logError } from './auditLog';
import { db } from '../db/database';

const REPO_URL = 'https://github.com/JsonLord/TREK.git';
const BRANCH = 'custom-data';
const dataDir = path.join(__dirname, '../../data');
const dbPath = path.join(dataDir, 'travel.db');
const syncDir = path.join(dataDir, 'github-sync');

export async function runGithubSync(): Promise<void> {
  const token = process.env.PAT_TOKEN;
  if (!token) {
    logError('GitHub Sync: PAT_TOKEN not found in environment');
    return;
  }

  const authenticatedRepoUrl = `https://x-access-token:${token}@github.com/JsonLord/TREK.git`;

  try {
    if (!fs.existsSync(syncDir)) {
      logInfo(`GitHub Sync: Cloning repository into ${syncDir}`);
      execSync(`git clone ${authenticatedRepoUrl} ${syncDir}`, { stdio: 'ignore' });

      // Check if branch exists, otherwise create it
      const branches = execSync(`git -C ${syncDir} branch -a`, { encoding: 'utf8' });
      if (branches.includes(`remotes/origin/${BRANCH}`)) {
        execSync(`git -C ${syncDir} checkout ${BRANCH}`, { stdio: 'ignore' });
      } else {
        logInfo(`GitHub Sync: Creating new branch ${BRANCH}`);
        execSync(`git -C ${syncDir} checkout -b ${BRANCH}`, { stdio: 'ignore' });
        execSync(`git -C ${syncDir} push -u origin ${BRANCH}`, { stdio: 'ignore' });
      }
    } else {
      logInfo('GitHub Sync: Pulling latest changes');
      execSync(`git -C ${syncDir} pull origin ${BRANCH}`, { stdio: 'ignore' });
    }

    // Flush WAL to main DB file before copying
    try {
      db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      logError(`GitHub Sync: Failed to flush WAL: ${e instanceof Error ? e.message : e}`);
    }

    const destDbPath = path.join(syncDir, 'travel.db');
    fs.copyFileSync(dbPath, destDbPath);

    // Force add because .db is usually ignored in TREK
    execSync(`git -C ${syncDir} add -f travel.db`, { stdio: 'ignore' });

    // Check if there are changes
    const status = execSync(`git -C ${syncDir} status --porcelain`, { encoding: 'utf8' });
    if (!status) {
      logInfo('GitHub Sync: No changes to push');
      return;
    }

    logInfo('GitHub Sync: Committing and pushing changes');
    execSync(`git -C ${syncDir} -c user.name="TREK Sync" -c user.email="sync@trek.local" commit -m "Update database: ${new Date().toISOString()}"`, { stdio: 'ignore' });
    execSync(`git -C ${syncDir} push origin ${BRANCH}`, { stdio: 'ignore' });
    logInfo('GitHub Sync: Success');

  } catch (err: unknown) {
    logError(`GitHub Sync failed: ${err instanceof Error ? err.message : err}`);
  }
}
