pipeline {
  agent any

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

    stage('Validate Kustomize Manifests') {
      steps {
        script {
          echo "Checking Kustomize syntax for all environments..."
          sh 'kustomize build apps/dev > /dev/null'
          sh 'kustomize build apps/staging > /dev/null'
          sh 'kustomize build apps/prod > /dev/null'
          sh 'kustomize build platform > /dev/null'
          echo "✅ All Kubernetes/Kustomize manifests are valid!"
        }
      }
    }

    stage('Update Image Tag') {
      when {
        expression { return params.UPDATE_IMAGE == true && params.NEW_TAG != '' }
      }
      steps {
        script {
          dir("apps/${params.ENVIRONMENT}") {
            echo "Updating ${params.SERVICE_NAME} to tag ${params.NEW_TAG} in ${params.ENVIRONMENT}..."
            sh "kustomize edit set image 602367507570.dkr.ecr.us-east-1.amazonaws.com/${params.SERVICE_NAME}=602367507570.dkr.ecr.us-east-1.amazonaws.com/${params.SERVICE_NAME}:${params.NEW_TAG}"
          }
          
          withCredentials([gitUsernamePassword(credentialsId: 'github-credentials', gitToolName: 'git-default')]) {
            sh """
              git config user.name "Jenkins CI"
              git config user.email "jenkins@company.com"
              git add apps/${params.ENVIRONMENT}/kustomization.yaml
              git commit -m "ci: update ${params.SERVICE_NAME} image tag to ${params.NEW_TAG} in ${params.ENVIRONMENT}"
              git push origin main
            """
          }
          echo "🚀 Updated image tag and pushed to GitOps repo! ArgoCD will now auto-deploy."
        }
      }
    }
  }

  post {
    always {
      cleanWs()
    }
  }
}
