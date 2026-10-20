ARG RUBY_VERSION=4.0
FROM ruby:${RUBY_VERSION}

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH=/root/.local/bin:${PATH}
ENV IS_SANDBOX=1

# Disable Claude's onboarding flow (it opens even if the token is present)
RUN mkdir -p /root/.claude-sandbox && echo '{"hasCompletedOnboarding":true}' > /root/.claude-sandbox/.claude.json
