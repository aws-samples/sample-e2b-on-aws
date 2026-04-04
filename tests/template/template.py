from e2b import Template

template = (
    Template()
    .from_image("e2bdev/base")
    .run_cmd("echo Hello World E2B!")
)