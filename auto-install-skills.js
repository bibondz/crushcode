#!/usr/bin/env node

/**
 * auto-install-skills.js
 * 
 * Auto-detect tech stack from project and install relevant skills from skills.sh
 * 
 * Usage: node auto-install-skills.js [--dry-run] [--force]
 */

import { readFileSync, readdirSync, existsSync, mkdirSync, writeFileSync, cpSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILLS_DIR = join(process.env.HOME || process.env.USERPROFILE || '', '.opencode', 'skills');

// Tech to Skills.sh mapping
const TECH_SKILLS_MAP = {
  // React/Next.js
  'react': ['vercel-react-best-practices', 'typescript-advanced-types'],
  'next': ['next-best-practices', 'next-cache-components', 'next-upgrade', 'vercel-react-best-practices'],
  'react-dom': ['vercel-react-best-practices'],
  '@types/react': ['typescript-advanced-types'],
  
  // Vue
  'vue': ['vue-best-practices'],
  'nuxt': ['nuxt', 'vue-best-practices'],
  '@nuxtjs': ['nuxt'],
  'pinia': ['vue-pinia-best-practices'],
  
  // Svelte
  'svelte': ['svelte5-best-practices'],
  
  // Tailwind
  'tailwindcss': ['tailwind-css-patterns'],
  '@tailwindcss': ['tailwind-css-patterns'],
  
  // shadcn/ui
  'shadcn-ui': ['shadcn'],
  '@shadcn/ui': ['shadcn'],
  
  // TypeScript (always useful)
  'typescript': ['typescript-advanced-types'],
  '@types/typescript': ['typescript-advanced-types'],
  
  // Node.js
  'express': ['nodejs-backend-patterns'],
  'hono': ['hono'],
  'fastify': ['nodejs-best-practices'],
  'koa': ['nodejs-best-practices'],
  
  // Python
  'django': ['django-expert'],
  'fastapi': ['fastapi', 'fastapi-python'],
  'flask': ['flask'],
  'pydantic': ['pydantic'],
  'sqlalchemy': ['sqlalchemy-orm'],
  
  // Database
  '@prisma/client': ['prisma-client-api', 'prisma-database-setup'],
  'prisma': ['prisma-cli'],
  'drizzle-orm': ['drizzle-orm'],
  'supabase': ['supabase-postgres-best-practices'],
  
  // Auth
  'clerk': ['clerk', 'clerk-setup'],
  'better-auth': ['better-auth-best-practices'],
  '@auth/core': ['better-auth-best-practices'],
  '@clerk/backend': ['clerk-backend-api'],
  
  // Stripe
  'stripe': ['stripe-best-practices'],
  
  // Go
  // Go modules in go.mod - handled separately
  
  // Deno
  // Deno - handled separately
  
  // Cloudflare
  '@cloudflare/workers': ['cloudflare', 'workers-best-practices'],
  'wrangler': ['wrangler'],
  
  // AWS
  '@aws-sdk': ['aws-sdk-patterns'],
  
  // Azure
  '@azure/arm': ['azure-deploy'],
  '@azure/functions': ['azure-deploy'],
  
  // Testing
  'vitest': ['vitest', 'playwright-best-practices'],
  'playwright': ['playwright-best-practices'],
  'jest': ['playwright-best-practices'],
  '@testing-library/react': ['playwright-best-practices'],
  
  // Animation
  'gsap': ['gsap-core', 'gsap-timeline', 'gsap-scrolltrigger', 'gsap-performance'],
  'framer-motion': ['react-animation'],
  'react-spring': ['react-animation'],
  
  // Three.js
  'three': ['threejs-fundamentals', 'threejs-animation'],
  '@react-three/fiber': ['threejs-fundamentals'],
  '@react-three/drei': ['threejs-fundamentals'],
  
  // Mobile
  'expo': ['expo-tailwind-setup', 'building-native-ui'],
  'react-native': ['sleek-design-mobile-apps'],
  
  // Flutter
  // Flutter - handled separately
  
  // Android
  // Gradle/Kotlin - handled separately
  
  // Rails
  // Gemfile - handled separately
  
  // Misc
  'turbo': ['turborepo'],
  '@vercel/turbo': ['turborepo'],
  
  // Terraform
  'terraform': ['terraform-style-guide'],
};

// Skills.sh URLs
const SKILLS_URLS = {
  // React/Next.js
  'vercel-react-best-practices': 'https://skills.sh/vercel-labs/agent-skills/vercel-react-best-practices',
  'vercel-composition-patterns': 'https://skills.sh/vercel-labs/agent-skills/vercel-composition-patterns',
  'next-best-practices': 'https://skills.sh/vercel-labs/next-skills/next-best-practices',
  'next-cache-components': 'https://skills.sh/vercel-labs/next-skills/next-cache-components',
  'next-upgrade': 'https://skills.sh/vercel-labs/next-skills/next-upgrade',
  
  // Vue
  'vue-best-practices': 'https://skills.sh/antfu/skills/vue-best-practices',
  'vue-debug-guides': 'https://skills.sh/hyf0/vue-skills/vue-debug-guides',
  'nuxt': 'https://skills.sh/antfu/skills/nuxt',
  'vue-pinia-best-practices': 'https://skills.sh/vuejs-ai/skills/vue-pinia-best-practices',
  
  // TypeScript
  'typescript-advanced-types': 'https://skills.sh/wshobson/agents/typescript-advanced-types',
  
  // Node.js
  'nodejs-backend-patterns': 'https://skills.sh/wshobson/agents/nodejs-backend-patterns',
  'nodejs-best-practices': 'https://skills.sh/sickn33/antigravity-awesome-skills/nodejs-best-practices',
  
  // Python
  'django-expert': 'https://skills.sh/vintasoftware/django-ai-plugins/django-expert',
  'django-patterns': 'https://skills.sh/affaan-m/everything-claude-code/django-patterns',
  'django-security': 'https://skills.sh/affaan-m/everything-claude-code/django-security',
  'fastapi': 'https://skills.sh/wshobson/agents/fastapi-templates',
  'fastapi-python': 'https://skills.sh/mindrally/skills/fastapi-python',
  'flask': 'https://skills.sh/jezweb/claude-skills/flask',
  'pydantic': 'https://skills.sh/bobmatnyc/claude-mpm-skills/pydantic',
  'sqlalchemy-orm': 'https://skills.sh/bobmatnyc/claude-mpm-skills/sqlalchemy-orm',
  
  // Go (not in skills.sh yet, placeholder)
  'golang-patterns': 'https://skills.sh/affaan-m/everything-claude-code/golang-patterns',
  'golang-testing': 'https://skills.sh/affaan-m/everything-claude-code/golang-testing',
  
  // Deno
  'deno-expert': 'https://skills.sh/denoland/skills/deno-expert',
  'deno-guidance': 'https://skills.sh/denoland/skills/deno-guidance',
  'deno-deploy': 'https://skills.sh/denoland/skills/deno-deploy',
  
  // Database
  'prisma-client-api': 'https://skills.sh/prisma/skills/prisma-client-api',
  'prisma-database-setup': 'https://skills.sh/prisma/skills/prisma-database-setup',
  'prisma-cli': 'https://skills.sh/prisma/skills/prisma-cli',
  'drizzle-orm': 'https://skills.sh/bobmatnyc/claude-mpm-skills/drizzle-orm',
  'supabase-postgres-best-practices': 'https://skills.sh/supabase/agent-skills/supabase-postgres-best-practices',
  
  // Auth
  'clerk': 'https://skills.sh/clerk/skills/clerk',
  'clerk-setup': 'https://skills.sh/clerk/skills/clerk-setup',
  'clerk-custom-ui': 'https://skills.sh/clerk/skills/clerk-custom-ui',
  'clerk-backend-api': 'https://skills.sh/clerk/skills/clerk-backend-api',
  'clerk-orgs': 'https://skills.sh/clerk/skills/clerk-orgs',
  'clerk-webhooks': 'https://skills.sh/clerk/skills/clerk-webhooks',
  'clerk-testing': 'https://skills.sh/clerk/skills/clerk-testing',
  'better-auth-best-practices': 'https://skills.sh/better-auth/skills/better-auth-best-practices',
  'two-factor-authentication-best-practices': 'https://skills.sh/better-auth/skills/two-factor-authentication-best-practices',
  
  // Payments
  'stripe-best-practices': 'https://skills.sh/stripe/ai/stripe-best-practices',
  
  // UI
  'tailwind-css-patterns': 'https://skills.sh/giuseppe-trisciuoglio/developer-kit/tailwind-css-patterns',
  'shadcn': 'https://skills.sh/shadcn/ui/shadcn',
  
  // Testing
  'vitest': 'https://skills.sh/antfu/skills/vitest',
  'playwright-best-practices': 'https://skills.sh/currents-dev/playwright-best-practices-skill/playwright-best-practices',
  
  // Cloud
  'cloudflare': 'https://skills.sh/cloudflare/skills/cloudflare',
  'workers-best-practices': 'https://skills.sh/cloudflare/skills/workers-best-practices',
  'wrangler': 'https://skills.sh/cloudflare/skills/wrangler',
  'durable-objects': 'https://skills.sh/cloudflare/skills/durable-objects',
  'azure-deploy': 'https://skills.sh/microsoft/github-copilot-for-azure/azure-deploy',
  'azure-ai': 'https://skills.sh/microsoft/github-copilot-for-azure/azure-ai',
  
  // Turborepo
  'turborepo': 'https://skills.sh/vercel/turborepo/turborepo',
  
  // GSAP
  'gsap-core': 'https://skills.sh/greensock/gsap-skills/gsap-core',
  'gsap-timeline': 'https://skills.sh/greensock/gsap-skills/gsap-timeline',
  'gsap-scrolltrigger': 'https://skills.sh/greensock/gsap-skills/gsap-scrolltrigger',
  'gsap-performance': 'https://skills.sh/greensock/gsap-skills/gsap-performance',
  'gsap-plugins': 'https://skills.sh/greensock/gsap-skills/gsap-plugins',
  'gsap-utils': 'https://skills.sh/greensock/gsap-skills/gsap-utils',
  'gsap-frameworks': 'https://skills.sh/greensock/gsap-skills/gsap-frameworks',
  
  // Three.js
  'threejs-fundamentals': 'https://skills.sh/cloudai-x/threejs-skills/threejs-fundamentals',
  'threejs-animation': 'https://skills.sh/cloudai-x/threejs-skills/threejs-animation',
  'threejs-shaders': 'https://skills.sh/cloudai-x/threejs-skills/threejs-shaders',
  'threejs-geometry': 'https://skills.sh/cloudai-x/threejs-skills/threejs-geometry',
  
  // Mobile
  'building-native-ui': 'https://skills.sh/expo/skills/building-native-ui',
  'sleek-design-mobile-apps': 'https://skills.sh/sleekdotdesign/agent-skills/sleek-design-mobile-apps',
  
  // Ruby/Rails
  'ruby-on-rails-best-practices': 'https://skills.sh/sergiodxa/agent-skills/ruby-on-rails-best-practices',
  'rails-guides': 'https://skills.sh/lucianghinda/superpowers-ruby/rails-guides',
  
  // Terraform
  'terraform-style-guide': 'https://skills.sh/hashicorp/agent-skills/terraform-style-guide',
};

// Default skills to always install (useful for any project)
const DEFAULT_SKILLS = ['typescript-advanced-types'];

// Colors
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  dim: '\x1b[2m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
};

function log(msg, color = 'reset') {
  console.log(`${colors[color]}${msg}${colors.reset}`);
}

function detectTechStack() {
  const detected = new Set();
  
  // 1. package.json (Node.js / JavaScript projects)
  if (existsSync('package.json')) {
    try {
      const pkg = JSON.parse(readFileSync('package.json', 'utf-8'));
      const deps = { ...pkg.dependencies, ...pkg.devDependencies };
      
      for (const [dep, skills] of Object.entries(TECH_SKILLS_MAP)) {
        if (deps[dep]) {
          if (Array.isArray(skills)) {
            skills.forEach(s => detected.add(s));
          } else {
            detected.add(skills);
          }
        }
      }
    } catch (e) {
      log('Warning: Could not parse package.json', 'yellow');
    }
  }
  
  // 2. requirements.txt (Python)
  if (existsSync('requirements.txt')) {
    try {
      const content = readFileSync('requirements.txt', 'utf-8');
      const lines = content.split('\n').map(l => l.split('==')[0].split('>=')[0].trim().toLowerCase());
      
      for (const [dep, skills] of Object.entries(TECH_SKILLS_MAP)) {
        if (lines.some(l => l === dep.toLowerCase() || l.startsWith(dep.toLowerCase() + '-'))) {
          if (Array.isArray(skills)) {
            skills.forEach(s => detected.add(s));
          } else {
            detected.add(skills);
          }
        }
      }
    } catch (e) {
      log('Warning: Could not read requirements.txt', 'yellow');
    }
  }
  
  // 3. go.mod (Go)
  if (existsSync('go.mod')) {
    try {
      const content = readFileSync('go.mod', 'utf-8');
      const lines = content.split('\n');
      
      // Add basic Go skills
      detected.add('golang-patterns');
      
      // Check for specific frameworks
      if (content.includes('gin-gonic') || content.includes('gin')) {
        detected.add('golang-patterns');
      }
      if (content.includes('fiber')) {
        detected.add('golang-patterns');
      }
    } catch (e) {
      log('Warning: Could not read go.mod', 'yellow');
    }
  }
  
  // 4. Cargo.toml (Rust)
  if (existsSync('Cargo.toml')) {
    detected.add('rust-best-practices');
  }
  
  // 5. pubspec.yaml (Flutter)
  if (existsSync('pubspec.yaml')) {
    try {
      const content = readFileSync('pubspec.yaml', 'utf-8');
      
      detected.add('flutter-expert');
      
      if (content.includes('flutter:')) {
        detected.add('flutter-expert');
      }
    } catch (e) {
      log('Warning: Could not read pubspec.yaml', 'yellow');
    }
  }
  
  // 6. build.gradle (Android)
  if (existsSync('build.gradle') || existsSync('build.gradle.kts')) {
    detected.add('android-kotlin-core');
    detected.add('android-compose-foundations');
  }
  
  // 7. Gemfile (Ruby)
  if (existsSync('Gemfile')) {
    detected.add('ruby-on-rails-best-practices');
    detected.add('rails-guides');
  }
  
  // 8. pyproject.toml (Python with modern tooling)
  if (existsSync('pyproject.toml')) {
    try {
      const content = readFileSync('pyproject.toml', 'utf-8');
      
      if (content.includes('fastapi')) {
        detected.add('fastapi');
        detected.add('fastapi-python');
      }
      if (content.includes('django')) {
        detected.add('django-expert');
      }
      if (content.includes('flask')) {
        detected.add('flask');
      }
    } catch (e) {
      log('Warning: Could not read pyproject.toml', 'yellow');
    }
  }
  
  // 9. deno.json (Deno)
  if (existsSync('deno.json') || existsSync('deno.jsonc')) {
    detected.add('deno-expert');
    detected.add('deno-typescript');
  }
  
  // 10. main.tf (Terraform)
  if (existsSync('main.tf') || existsSync('variables.tf')) {
    detected.add('terraform-style-guide');
  }

  // 11. build.zig (Zig projects)
  if (existsSync('build.zig') || existsSync('build.zig.zon')) {
    detected.add('zig-patterns');
  }
  
  return Array.from(detected);
}

async function fetchSkillContent(url) {
  try {
    // Simple fetch using Node.js native fetch (Node 18+)
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const html = await response.text();
    
    // Extract SKILL.md content from the page
    // The content is in a markdown-like format in the page
    const skillMatch = html.match(/<pre[^>]*>([\s\S]*?)<\/pre>/);
    if (skillMatch) {
      return skillMatch[1].replace(/<[^>]+>/g, '').trim();
    }
    
    // Alternative: look for the main content
    const contentMatch = html.match(/<main[^>]*>([\s\S]*?)<\/main>/);
    if (contentMatch) {
      // Strip HTML tags
      return contentMatch[1]
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
    }
    
    // Try to find a pre tag with the skill content
    const preMatch = html.match(/<pre class="[^"]*">([\s\S]*?)<\/pre>/);
    if (preMatch) {
      return preMatch[1].trim();
    }
    
    return null;
  } catch (e) {
    console.error(`Error fetching ${url}:`, e.message);
    return null;
  }
}

function createSkillMetadata(skillName, description = '') {
  const triggerPhrases = getTriggerPhrases(skillName);
  
  return {
    name: skillName,
    description: description || `Best practices for ${skillName}`,
    triggers: triggerPhrases,
    source: 'skills.sh'
  };
}

function getTriggerPhrases(skillName) {
  const baseTriggers = {
    'gsap-core': ['gsap', 'tween', 'animation', 'gsap.to', 'gsap.from'],
    'gsap-timeline': ['timeline', 'sequence', 'sequencing'],
    'gsap-scrolltrigger': ['scroll', 'scrolltrigger', 'pinning', 'scrub'],
    'gsap-performance': ['performance', 'fps', 'jank', 'optimize'],
    'next-best-practices': ['next.js', 'nextjs', 'next.js routing'],
    'vercel-react-best-practices': ['react', 'components', 'hooks'],
    'vue-best-practices': ['vue', 'vue3', 'composition api'],
    'django-expert': ['django', 'django model', 'django view'],
    'fastapi': ['fastapi', 'python api', 'pydantic'],
    'playwright-best-practices': ['playwright', 'e2e', 'testing', 'test'],
    'tailwind-css-patterns': ['tailwind', 'css', 'styling'],
    'stripe-best-practices': ['stripe', 'payment', 'billing'],
    'clerk': ['clerk', 'auth', 'authentication'],
    'prisma-client-api': ['prisma', 'database', 'orm'],
    'supabase-postgres-best-practices': ['supabase', 'postgres', 'database'],
  };
  
  return baseTriggers[skillName] || [skillName.replace(/-/g, ' ').replace(/_/g, ' ')];
}

async function installSkill(skillName, dryRun = false) {
  const url = SKILLS_URLS[skillName];
  if (!url) {
    log(`Skipping ${skillName}: no URL mapping`, 'yellow');
    return false;
  }
  
  const skillDir = join(SKILLS_DIR, skillName);
  
  if (!dryRun) {
    mkdirSync(skillDir, { recursive: true });
  }
  
  log(`Installing ${skillName}...`, 'blue');
  
  // Try to fetch content
  // For now, just create metadata - content can be fetched on demand
  const metadata = createSkillMetadata(skillName);
  
  if (!dryRun) {
    const skillJsonPath = join(skillDir, 'skill.json');
    writeFileSync(skillJsonPath, JSON.stringify(metadata, null, 2));
    
    // Create a README with installation instructions
    const readmeContent = `# ${skillName}

## Installation
\`\`\`bash
npx skills add ${url}
\`\`\`

## Source
This skill is sourced from [skills.sh](${url})

## Trigger Phrases
${metadata.triggers.map(t => `- "${t}"`).join('\n')}

## Description
${metadata.description}
`;
    writeFileSync(join(skillDir, 'README.md'), readmeContent);
    
    log(`✓ Installed ${skillName}`, 'green');
  } else {
    log(`[DRY-RUN] Would install ${skillName}`, 'magenta');
  }
  
  return true;
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes('--dry-run');
  const force = args.includes('--force');
  
  log('🔍 Detecting tech stack...', 'blue');
  
  const detectedSkills = detectTechStack();
  
  // Add default skills
  const skillsToInstall = [...new Set([...DEFAULT_SKILLS, ...detectedSkills])];
  
  if (skillsToInstall.length === 0) {
    log('No specific tech detected. Installing default skills...', 'yellow');
  }
  
  log(`\n📦 Found skills: ${skillsToInstall.join(', ')}`, 'green');
  
  if (dryRun) {
    log('\n[DRY-RUN MODE]\n', 'magenta');
  }
  
  // Ensure skills directory exists
  if (!dryRun) {
    mkdirSync(SKILLS_DIR, { recursive: true });
  }
  
  // Install each skill
  let installed = 0;
  for (const skill of skillsToInstall) {
    const success = await installSkill(skill, dryRun);
    if (success) installed++;
  }
  
  log(`\n✅ ${dryRun ? '[DRY-RUN] ' : ''}Installed ${installed} skills to ${SKILLS_DIR}`, 'green');
  
  // Create a helper script for OpenCode
  if (!dryRun) {
    const helperPath = join(SKILLS_DIR, 'load-skills.js');
    const helperContent = `// Auto-generated helper
// This file helps OpenCode load skills automatically

const fs = require('fs');
const path = require('path');

const skillsDir = __dirname;

function getInstalledSkills() {
  if (!fs.existsSync(skillsDir)) return [];
  return fs.readdirSync(skillsDir).filter(f => {
    const stat = fs.statSync(path.join(skillsDir, f));
    return stat.isDirectory();
  });
}

module.exports = { getInstalledSkills, skillsDir };
`;
    writeFileSync(helperPath, helperContent);
    log(`📝 Created helper at ${helperPath}`, 'blue');
  }
}

main().catch(console.error);