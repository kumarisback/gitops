pipeline {
  // ci/Dockerfile pins every tool scripts/validate.sh needs (kubectl,
  // kustomize, helm, kubeconform, promtool, amtool, alloy, otelcol-contrib,
  // loki), so a build validates with the same versions the clusters run.
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
    booleanParam(name: 'UPDATE_IMAGE', defaultValue: false, description: 'Check this box to update a service image tag')
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment to update')
    choice(name: 'SERVICE_NAME', choices: ['frontend', 'user-service', 'order-service'], description: 'Service to update')
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
        dir("apps/${params.ENVIRONMENT}") {
          echo "Updating ${params.SERVICE_NAME} to tag ${params.NEW_TAG} in ${params.ENVIRONMENT}..."
          sh "kustomize edit set image 602367507570.dkr.ecr.us-east-1.amazonaws.com/${params.SERVICE_NAME}=602367507570.dkr.ecr.us-east-1.amazonaws.com/${params.SERVICE_NAME}:${params.NEW_TAG}"
        }
      }
    }

    // Runs on every build, and after an image-tag edit so a broken change
    // is never pushed. Renders every environment's overlays and Helm
    // add-ons and checks them with each component's own parser.
    stage('Validate') {
      steps {
        sh './scripts/validate.sh'
      }
    }

    stage('Push Image Tag') {
      when {
        expression { return params.UPDATE_IMAGE == true && params.NEW_TAG != '' }
      }
      steps {
        withCredentials([gitUsernamePassword(credentialsId: 'github-credentials', gitToolName: 'git-default')]) {
          sh """
            git config user.name "Jenkins CI"
            git config user.email "jenkins@company.com"
            git add apps/${params.ENVIRONMENT}/kustomization.yaml
            git commit -m "ci: update ${params.SERVICE_NAME} image tag to ${params.NEW_TAG} in ${params.ENVIRONMENT}"
            git push origin HEAD:main
          """
        }
        echo "🚀 Updated image tag and pushed to GitOps repo! ArgoCD will now auto-deploy."
      }
    }
  }

  post {
    always {
      // Per-check logs and the rendered manifests, for failed builds.
      archiveArtifacts artifacts: '.validate/logs/**,.validate/kustomize/**,.validate/helm/**', allowEmptyArchive: true
      cleanWs()
    }
  }
}
