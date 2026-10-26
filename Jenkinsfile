pipeline {
  // ci/Dockerfile pins every tool scripts/validate.sh needs (kubectl,
  // kustomize, helm + helm-unittest, kubeconform, promtool, amtool, alloy, otelcol-contrib,
  // loki, blackbox_exporter), so a build validates with the same versions the clusters run.
  agent {
    dockerfile {
      dir 'ci'
    }
  }

  options {
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  parameters {
    booleanParam(name: 'UPDATE_IMAGE', defaultValue: false, description: 'Check this box to open a pull request that updates a service image tag')
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment to update')
    choice(name: 'SERVICE_NAME', choices: ['frontend', 'user-service', 'order-service', 'notification-service'], description: 'Service to update')
    string(name: 'NEW_TAG', defaultValue: '', description: 'New Docker image tag (e.g., v1.2.0)')
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Update Image Tag') {
      when {
        expression { return params.UPDATE_IMAGE == true && params.NEW_TAG != '' }
      }
      steps {
        script {
          // Job parameters reach the shell only as environment variables in
          // single-quoted scripts (never Groovy string interpolation), and
          // only after matching these checks, so a crafted value can't run
          // commands on the agent.
          if (!(params.ENVIRONMENT in ['dev', 'staging', 'prod'])) {
            error("Invalid ENVIRONMENT: must be dev, staging or prod")
          }
          if (!(params.SERVICE_NAME in ['frontend', 'user-service', 'order-service', 'notification-service'])) {
            error("Invalid SERVICE_NAME: must be frontend, user-service, order-service or notification-service")
          }
          if (!(params.NEW_TAG ==~ /[A-Za-z0-9][A-Za-z0-9._-]{0,127}/)) {
            error("Invalid NEW_TAG: use letters, digits, '.', '_' or '-', up to 128 characters")
          }
        }
        withEnv(["TARGET_ENV=${params.ENVIRONMENT}", "SERVICE=${params.SERVICE_NAME}", "NEW_TAG=${params.NEW_TAG}"]) {
          sh '''
            set -eu
            echo "Updating ${SERVICE} to tag ${NEW_TAG} in ${TARGET_ENV}..."
            values="apps/${TARGET_ENV}/${SERVICE}.values.yaml"
            if [ -f "${values}" ]; then
              # Deployed from charts/microservice (order-service,
              # notification-service): the tag is image.tag in its values
              # file. Edited as text, so the file's comments stay.
              ruby -e 'file, tag = ARGV
                text = File.read(file)
                done = text.sub!(/^(image:\n(?:[ \t].*\n)*?  tag: ).*$/) { "#{$1}\"#{tag}\"" }
                abort("no image.tag in #{file}") unless done
                File.write(file, text)' "${values}" "${NEW_TAG}"
            else
              image="602367507570.dkr.ecr.us-east-1.amazonaws.com/${SERVICE}"
              cd "apps/${TARGET_ENV}"
              kustomize edit set image "${image}=${image}:${NEW_TAG}"
            fi
          '''
        }
      }
    }

    // Runs on every build, and after an image-tag edit so a broken change
    // never reaches a pull request. Renders every environment's overlays and
    // Helm add-ons and checks them with each component's own parser.
    stage('Validate') {
      steps {
        sh './scripts/validate.sh'
      }
    }

    // A merged chart change is published to ECR as an OCI artifact
    // (oci://<registry>/charts/microservice:<version>). Only from main, so
    // only reviewed charts are published; scripts/publish-chart.sh fails if
    // the chart changed without a version bump.
    //
    // It runs on the Jenkins host, not in the ci/Dockerfile container: the
    // instance role is reachable only from the host (IMDS hop limit 1, tf
    // modules/jenkins). The host fetches an ECR login token (push/pull only,
    // 12 hours) and pipes it into the container's Helm, so no container ever
    // holds the role's credentials, and the token never touches disk, an
    // environment variable or a command line.
    stage('Publish Chart') {
      agent any
      when {
        expression { return params.UPDATE_IMAGE != true && (env.BRANCH_NAME == 'main' || env.GIT_BRANCH in ['main', 'origin/main']) }
      }
      steps {
        sh '''
          set -eu
          docker build -q -t gitops-ci:publish ci > /dev/null
          aws ecr get-login-password --region us-east-1 |
            docker run --rm -i --user "$(id -u):$(id -g)" -v "$PWD:/repo" -w /repo \
              -e ECR_TOKEN_ON_STDIN=1 gitops-ci:publish ./scripts/publish-chart.sh charts/microservice
        '''
      }
    }

    // main is protected: an image change lands through a reviewed pull
    // request (validated by this same pipeline), never a direct push.
    stage('Open Pull Request') {
      when {
        expression { return params.UPDATE_IMAGE == true && params.NEW_TAG != '' }
      }
      steps {
        withEnv(["TARGET_ENV=${params.ENVIRONMENT}", "SERVICE=${params.SERVICE_NAME}", "NEW_TAG=${params.NEW_TAG}"]) {
          withCredentials([gitUsernamePassword(credentialsId: 'github-credentials', gitToolName: 'git-default')]) {
            sh '''
              set -eu
              branch="ci/${SERVICE}-${TARGET_ENV}-${NEW_TAG}"
              git config user.name "Jenkins CI"
              git config user.email "jenkins@company.com"
              git checkout -b "${branch}"
              git add "apps/${TARGET_ENV}/kustomization.yaml"
              [ -f "apps/${TARGET_ENV}/${SERVICE}.values.yaml" ] && git add "apps/${TARGET_ENV}/${SERVICE}.values.yaml"
              git commit -m "ci: update ${SERVICE} image tag to ${NEW_TAG} in ${TARGET_ENV}"
              git push origin "${branch}"

              # Credentials go to curl through a private file, not argv.
              auth="$(mktemp)"
              trap 'rm -f "${auth}"' EXIT
              chmod 600 "${auth}"
              printf 'user = "%s:%s"\\n' "${GIT_USERNAME}" "${GIT_PASSWORD}" > "${auth}"
              jq -n \
                --arg title "ci: ${SERVICE} ${NEW_TAG} -> ${TARGET_ENV}" \
                --arg head "${branch}" \
                --arg body "Image tag update requested by Jenkins build ${BUILD_URL}" \
                '{title: $title, head: $head, base: "main", body: $body}' |
                curl -fsS -K "${auth}" -H "Accept: application/vnd.github+json" \
                  -X POST https://api.github.com/repos/kumarisback/gitops/pulls -d @- |
                jq -r '"Opened " + .html_url'
            '''
          }
        }
      }
    }
  }

  post {
    always {
      // Per-check logs only; the rendered manifests include Secrets.
      archiveArtifacts artifacts: '.validate/logs/**', allowEmptyArchive: true
      cleanWs()
    }
  }
}
