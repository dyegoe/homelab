FROM public.ecr.aws/amazonlinux/amazonlinux@sha256:158a9044f9dc0777f098b76c8b54346f6ed4560b9a6a416dec7a5ba3bc483af4

ARG EMULATOR_VERSION=1.0.341
RUN microdnf swap -y gnupg2-minimal gnupg2 && microdnf clean all && \
    export GNUPGHOME=/tmp/aws-emulator-gnupg && mkdir -m 700 "$GNUPGHOME" && \
    curl -fsSLo /tmp/aws-emulator.rpm \
      "https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/aws-emulator-${EMULATOR_VERSION}-1-x86_64.rpm" && \
    curl -fsSLo /tmp/aws-emulator.rpm.sig \
      "https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/aws-emulator-${EMULATOR_VERSION}-1-x86_64.rpm.sig" && \
    curl -fsSLo /tmp/aws-publishing.asc https://downloads.aws.com/keys/gpg/current.asc && \
    gpg --batch --import /tmp/aws-publishing.asc && \
    test "$(gpg --batch --with-colons --fingerprint ssm-publishing@amazon.com | awk -F: '$1 == "fpr" { print $10; exit }')" = "98BCF336A3BE53B734E967C52E5BF49BD940F624" && \
    gpg --batch --verify /tmp/aws-emulator.rpm.sig /tmp/aws-emulator.rpm && \
    rpm -i /tmp/aws-emulator.rpm && \
    rm -rf /tmp/aws-emulator-gnupg && \
    rm /tmp/aws-emulator.rpm /tmp/aws-emulator.rpm.sig /tmp/aws-publishing.asc && \
    mkdir -p /home/emulator && chown 1000:1000 /home/emulator

USER 1000:1000
ENV HOME=/home/emulator
EXPOSE 9297
ENTRYPOINT ["aws-emulator", "--bind", "127.0.0.1", "--telemetry", "off"]
