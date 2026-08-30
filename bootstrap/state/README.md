# Terraform state bootstrap

このstackだけはlocal stateで一度applyし、root stackが利用するGCS backend bucketを作成する。

1. state管理者とCI principalをtfvarsへ設定する。
2. terraform init と terraform apply を実行する。
3. outputのbucket名をrootのbackend.tfへ設定する。
4. rootでterraform init -migrate-stateを実行し、local stateが残っていないことを確認する。

bucketはversioning、uniform access、public access prevention、prevent_destroyを必須とする。
