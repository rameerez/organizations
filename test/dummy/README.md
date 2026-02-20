# Organizations Gem Demo App

This is a demo Rails app showcasing the `organizations` gem. It's deployed at [organizations.rameerez.com](https://organizations.rameerez.com).

## Running locally

```bash
cd test/dummy
bin/setup
bin/dev
```

Open [http://localhost:3000](http://localhost:3000).

## Deploying

The demo app uses [Kamal](https://kamal-deploy.org/) for deployment.

### First-time setup

1. **Generate the Docker-specific Gemfile.lock:**

   ```bash
   cd test/dummy
   BUNDLE_GEMFILE=Gemfile.docker bundle install
   ```

   This creates `Gemfile.docker.lock`. This is necessary because the regular `Gemfile` references the gem via `gemspec path: "../.."`, which doesn't exist in Docker's build context. The Docker Gemfile fetches the gem from RubyGems instead.

2. **Set up deploy config:**

   ```bash
   cd test/dummy
   cp config/deploy.yml.example config/deploy.yml
   # Edit config/deploy.yml with your server IPs, registry, etc.
   ```

3. **Set up secrets:**

   ```bash
   cd test/dummy
   cp .kamal/secrets.example .kamal/secrets
   # Edit .kamal/secrets with your values
   ```

4. **Create master key (if not present):**

   ```bash
   cd test/dummy
   bin/rails credentials:edit
   ```

### Deploying

```bash
cd test/dummy
kamal deploy
```

### After updating the gem

When you release a new version of the `organizations` gem to RubyGems, update the demo:

```bash
cd test/dummy
BUNDLE_GEMFILE=Gemfile.docker bundle update organizations
kamal deploy
```

## Architecture notes

- **Gemfile vs Gemfile.docker**: The regular `Gemfile` uses the local gem code for development. `Gemfile.docker` fetches from RubyGems for deployment.
- **No authentication**: The demo auto-creates users and uses session-based "impersonation" to switch between them.
- **SQLite**: Uses SQLite for simplicity. Data persists in a Docker volume.
